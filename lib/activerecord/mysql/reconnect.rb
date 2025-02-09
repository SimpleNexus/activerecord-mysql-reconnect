require 'mysql2'
require 'logger'
require 'bigdecimal'
require 'strscan'

require 'active_record'
require 'active_record/connection_adapters/abstract_adapter'
require 'active_record/connection_adapters/abstract_mysql_adapter'
require 'active_record/connection_adapters/mysql2_adapter'
require 'active_record/connection_adapters/abstract/connection_pool'
require 'active_record/connection_adapters/abstract/transaction'

require 'activerecord/mysql/reconnect/version'
require 'activerecord/mysql/reconnect/base_ext'

require 'activerecord/mysql/reconnect/abstract_mysql_adapter_ext'
require 'activerecord/mysql/reconnect/mysql2_adapter_ext'
require 'activerecord/mysql/reconnect/connection_pool_ext'
require 'activerecord/mysql/reconnect/null_transaction_ext'

module Activerecord::Mysql::Reconnect
  DEFAULT_EXECUTION_TRIES = 3
  DEFAULT_EXECUTION_RETRY_WAIT = 0.5

  WITHOUT_RETRY_KEY = 'activerecord-mysql-reconnect-without-retry'

  HANDLE_ERROR = [
    ActiveRecord::StatementInvalid,
    Mysql2::Error,
    ActiveRecord::ConnectionNotEstablished
  ]

  @@handle_r_error_messages = {
    lost_connection: 'Lost connection to MySQL server during query',
  }

  @@handle_rw_error_messages = {
    gone_away: 'MySQL server has gone away',
    server_shutdown: 'Server shutdown in progress',
    closed_connection: 'closed MySQL connection',
    cannot_connect: "Can't connect to MySQL server",
    interrupted: 'Query execution was interrupted',
    access_denied: 'Access denied for user',
    read_only: 'The MySQL server is running with the --read-only option',
    cannot_connect_to_local: "Can't connect to local MySQL server", # When running in local sandbox, or using a socket file
    unknown_host: 'Unknown MySQL server host', # For DNS blips
    lost_connection: "Lost connection to MySQL server at 'reading initial communication packet'",
    not_connected: "MySQL client is not connected",
    killed: 'Connection was killed',
  }

  READ_SQL_REGEXP = /\A\s*(?:SELECT|SHOW|SET)\b/i

  RETRY_MODES = [:r, :rw, :force]
  DEFAULT_RETRY_MODE = :r

  class << self
    def handle_r_error_messages
      @@handle_r_error_messages
    end

    def handle_rw_error_messages
      @@handle_rw_error_messages
    end

    def execution_tries
      ActiveRecord::Base.execution_tries || DEFAULT_EXECUTION_TRIES
    end

    def execution_retry_wait
      wait = ActiveRecord::Base.execution_retry_wait || DEFAULT_EXECUTION_RETRY_WAIT
      wait.kind_of?(BigDecimal) ? wait : BigDecimal(wait.to_s)
    end

    def enable_retry
      !!ActiveRecord::Base.enable_retry
    end

    def retry_mode=(v)
      unless RETRY_MODES.include?(v)
        raise "Invalid retry_mode. Please set one of the following: #{RETRY_MODES.map {|i| i.inspect }.join(', ')}"
      end

      @activerecord_mysql_reconnect_retry_mode = v
    end

    def retry_mode
      @activerecord_mysql_reconnect_retry_mode || DEFAULT_RETRY_MODE
    end

    def retry_databases=(v)
      v ||= []

      unless v.kind_of?(Array)
        v = [v]
      end

      @activerecord_mysql_reconnect_retry_databases = v.map do |database|
        if database.instance_of?(Symbol)
          database = Regexp.escape(database.to_s)
          [/.*/, /\A#{database}\z/]
        else
          host = '%'
          database = database.to_s

          if database =~ /:/
            host, database = database.split(':', 2)
          end

          [create_pattern_match_regex(host), create_pattern_match_regex(database)]
        end
      end
    end

    def retry_databases
      @activerecord_mysql_reconnect_retry_databases || []
    end

    def retryable(opts)
      block     = opts.fetch(:proc)
      on_error  = opts[:on_error]
      conn      = opts[:connection]
      sql       = opts[:sql]
      tries     = self.execution_tries
      retval    = nil

      retryable_loop(tries) do |n|
        begin
          retval = block.call
          break
        rescue => e
          if enable_retry and (tries.zero? or n < tries) and should_handle?(e, opts)
            on_error.call if on_error
            wait = self.execution_retry_wait * n

            logger.warn("MySQL server has gone away. Trying to reconnect in #{wait.to_f} seconds. (#{build_error_message(e, sql, conn)})")
            sleep(wait)
            next
          else
            if enable_retry and n > 1
              logger.warn("Query retry failed. (#{build_error_message(e, sql, conn)})")
            end

            raise e
          end
        end
      end

      return retval
    end

    def logger
      if defined?(Rails)
        Rails.logger || ActiveRecord::Base.logger || Logger.new($stderr)
      else
        ActiveRecord::Base.logger || Logger.new($stderr)
      end
    end

    def without_retry
      begin
        Thread.current[WITHOUT_RETRY_KEY] = true
        yield
      ensure
        Thread.current[WITHOUT_RETRY_KEY] = nil
      end
    end

    def without_retry?
      !!Thread.current[WITHOUT_RETRY_KEY]
    end

    private

    def retryable_loop(n)
      if n.zero?
        loop { n += 1 ; yield(n) }
      else
        n.times {|i| yield(i + 1) }
      end
    end

    def should_handle?(e, opts = {})
      sql        = opts[:sql]
      retry_mode = opts[:retry_mode]
      conn       = opts[:connection]

      if without_retry?
        return false
      end

      if conn and not retry_databases.empty?
        conn_info = connection_info(conn)

        included = retry_databases.any? do |host, database|
          host =~ conn_info[:host] and database =~ conn_info[:database]
        end

        return false unless included
      end

      unless HANDLE_ERROR.any? {|i| e.kind_of?(i) }
        return false
      end

      unless Regexp.union(@@handle_r_error_messages.values + @@handle_rw_error_messages.values) =~ e.message
        return false
      end

      if sql and READ_SQL_REGEXP !~ sql
        if retry_mode == :r
          return false
        end

        if retry_mode != :force and Regexp.union(@@handle_r_error_messages.values) =~ e.message
          return false
        end
      end

      return true
    end

    def connection_info(conn)
      conn_info = {}

      if conn.kind_of?(Mysql2::Client)
        [:host, :database, :username].each {|k| conn_info[k] = conn.query_options[k] }
      elsif conn.kind_of?(Hash)
        conn_info = conn.dup
      end

      return conn_info
    end

    def create_pattern_match_regex(str)
      ss = StringScanner.new(str)
      buf = []

      until ss.eos?
        if (tok = ss.scan(/[^\\%_]+/))
          buf << Regexp.escape(tok)
        elsif (tok = ss.scan(/\\/))
          buf << Regexp.escape(ss.getch)
        elsif (tok = ss.scan(/%/))
          buf << '.*'
        elsif (tok = ss.scan(/_/))
          buf << '.'
        else
          raise 'must not happen'
        end
      end

      /\A#{buf.join}\z/
    end

    def build_error_message(e, sql, conn)
      msgs = {cause: "#{e.message} [#{e.class}]"}
      msgs[:sql] = sql if sql

      if conn
        conn_info = connection_info(conn)
        msgs[:connection] = [:host, :database, :username].map {|k| "#{k}=#{conn_info[k]}" }.join(";")
      end

      msgs.map {|k, v| "#{k}: #{v}" }.join(", ")
    end
  end # end of class methods
end
