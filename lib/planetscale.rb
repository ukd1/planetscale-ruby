# frozen_string_literal: true

require 'planetscale/version'
require 'ffi'

module PlanetScale
  class <<self
    def start(auth_method: Proxy::AUTH_AUTO, **kwargs)
      @proxy = PlanetScale::Proxy.new(auth_method: auth_method, **kwargs)
      @proxy.start
    end
  end

  class Proxy
    AUTH_SERVICE_TOKEN = 1 # Use Service Tokens for Auth
    AUTH_PSCALE = 2 # Use externally configured `pscale` auth & org config
    AUTH_STATIC = 3 # Use a locally provided certificate
    AUTH_AUTO = 4 # Default. Let the Gem figure it out
    PSCALE_FILE = '.pscale.yml'

    class ProxyError < StandardError
    end

    extend FFI::Library

    class ProxyReturn < FFI::Struct
      layout :r0, :pointer, :r1, :pointer
    end

    ffi_lib File.expand_path("../../proxy/planetscale-#{Gem::Platform.local.os}.so", __FILE__)
    attach_function :startfromenv, %i[string string string string], ProxyReturn.by_value
    attach_function :startfromtoken, %i[string string string string string string], ProxyReturn.by_value
    attach_function :startfromstatic, %i[string string string string string string string string string], ProxyReturn.by_value

    def initialize(auth_method: AUTH_AUTO, **kwargs)
      @auth_method = auth_method

      default_file = if defined?(Rails.root)
        File.join(Rails.root, PSCALE_FILE) if defined?(Rails.root)
      else
        PSCALE_FILE
      end

      @cfg_file = kwargs[:cfg_file] || ENV['PSCALE_DB_CONFIG'] || default_file

      @branch_name = kwargs[:branch] || ENV['PSCALE_DB_BRANCH']
      @branch = lookup_branch

      @db_name = kwargs[:db] || ENV['PSCALE_DB']
      @db = lookup_database

      @org_name = kwargs[:org] || ENV['PSCALE_ORG']
      @org = lookup_org

      raise ArgumentError, 'missing required configuration variables' if [@db, @branch, @org].any?(&:nil?)

      @token_name = kwargs[:token_id] || ENV['PSCALE_TOKEN_NAME']
      @token = kwargs[:token] || ENV['PSCALE_TOKEN']

      if @token && @token_name && auto_auth?
        @auth_method = AUTH_SERVICE_TOKEN
      end

      raise ArgumentError, 'missing configured service token auth' if token_auth? && [@token_name, @token].any?(&:nil?)

      @priv_key = kwargs[:private_key]
      @cert_chain = kwargs[:cert_chain]
      @remote_addr = kwargs[:remote_addr]
      @certificate = kwargs[:certificate]
      @port = kwargs[:port]

      if local_auth? && [@priv_key, @certificate, @cert_chain, @remote_addr, @port].any?(&:nil?)
        raise ArgumentError, 'missing configuration options for auth'
      end

      @listen_addr = kwargs[:listen_addr] || ENV['LISTEN_ADDR']
    end

    def start
      ret = case @auth_method
      when AUTH_PSCALE
        startfromenv(@org, @db, @branch, @listen_addr)
      when AUTH_AUTO
        startfromenv(@org, @db, @branch, @listen_addr)
      when AUTH_SERVICE_TOKEN
        startfromtoken(@token_name, @token, @org, @db, @branch, @listen_addr)
      when AUTH_STATIC
        startfromstatic(@org, @db, @branch, @priv_key, @certificate, @cert_chain, @remote_addr, @port, @listen_addr)
      end
      @err = ret[:r1].null? ? nil : ret[:r1].read_string
      raise(ProxyError, @err) if @err
    end

    private

    def lookup_branch
      return @branch_name if @branch_name
      return nil unless File.exist?(@cfg_file)

      cfg_file['branch']
    end

    def lookup_database
      return @db_name if @db_name
      return nil unless File.exist?(@cfg_file)

      cfg_file['database']
    end

    def lookup_org
      return @org_name if @org_name
      return nil unless File.exist?(@cfg_file)

      cfg_file['org']
    end

    def cfg_file
      @cfg ||= YAML.safe_load(File.read(@cfg_file))
    end

    def local_auth?
      @auth_method == AUTH_STATIC
    end

    def env_auth?
      @auth_method == AUTH_PSCALE
    end

    def token_auth?
      @auth_method == AUTH_SERVICE_TOKEN
    end

    def auto_auth?
      @auth_method == AUTH_AUTO
    end
  end
end
