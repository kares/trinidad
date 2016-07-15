require 'jruby'

module Trinidad
  module Logging

    # @private
    JUL = Java::JavaUtilLogging
    # @private
    LogFactory = Java::OrgApacheJuliLogging::LogFactory

    # A message formatter only prints the log message (and the thrown value).
    # @private
    MessageFormatter = Java::RbTrinidadLogging::MessageFormatter
    # @private
    DefaultFormatter = Java::RbTrinidadLogging::DefaultFormatter

    @@configured = nil

    # Configure the ("global") logging sub-system.
    # If invoked twice, does only actually configure once.
    def self.configure(config = nil)
      return false if @@configured
      @@configured = true

      root_logger = JUL::Logger.getLogger('')
      if config.is_a?(Hash)
        level = parse_log_level(:INFO)
      else
        level = parse_log_level(config, :INFO); config = false
      end

      runtime_out = JRuby.runtime.out
      runtime_err = JRuby.runtime.err
      out_handler = new_console_handler runtime_out
      out_handler.formatter = console_formatter

      root_logger.synchronized do
        root_logger.handlers.to_a.each do |handler|
          root_logger.remove_handler(handler) if handler.is_a?(JUL::ConsoleHandler)
        end

        root_logger.add_handler(out_handler)
        if ! runtime_out.equal?(Java::JavaLang::System.out) ||
           ! runtime_err.equal?(Java::JavaLang::System.err)
         # NOTE: only add err handler if customized STDOUT or STDERR :
        err_handler = new_console_handler runtime_err
        err_handler.formatter = console_formatter; warn = JUL::Level::WARNING
        err_handler.level = level.intValue > warn.intValue ? level : warn # only >= WARNING on STDERR

         root_logger.add_handler(err_handler)
        end
        set_log_level(root_logger, level)
      end
      silence_tomcat_loggers

      config.each do |logger, level|
        if level = parse_log_level(level, nil)
          set_log_level JUL::Logger.getLogger(logger.to_s), level
        end
      end if config

      root_logger
    end

    # Force logging re-configuration.
    # @see #configure
    def self.configure!(log_level = nil)
      ( @@configured = false ) || configure(log_level)
    end

    def self.configure_web_app!(web_app, context)
      configure_web_app!(web_app, context, true)
    end

    # Configure logging for a web application.
    def self.configure_web_app(web_app, context, reset = nil)
      param_name, param_value = 'jruby.rack.logging', 'JUL'
      # 1. delegate (jruby-rack) servlet log to JUL
      if set_value = web_app_context_param(web_app, context, param_name)
        return nil if set_value.upcase != param_value
      else
        context.add_parameter(param_name, param_value)
      end
      # 2. use Tomcat's JUL logger name (unless set) :
      param_name = 'jruby.rack.logging.name'
      unless logger_name = web_app_context_param(web_app, context, param_name)
        # for a context path e.g. '/foo' most likely smt of the following :
        # org.apache.catalina.core.ContainerBase.[Tomcat].[localhost].[/foo]
        context.add_parameter(param_name, logger_name = context.send(:logName))
      end
      configure # make sure 'global' logging is configured

      logger = JUL::Logger.getLogger(logger_name) # exclusive for web app
      logger.handlers.each { |h| logger.remove_handler(h); h.close } if reset
      # avoid duplicate calls - do not configure (e.g. FileHandler) twice :
      return false unless logger.handlers.empty?

      logging = web_app.logging

      logger.level = parse_log_level(logging[:level], nil)
      # delegate to root (console) output only in development mode :
      logger.use_parent_handlers = logging[:use_parent_handlers]
      # logging:
      #  file:
      #    dir: log # [RAILS_ROOT]/log
      #    prefix: production
      #    suffix: .log
      if file = logging[:file]
        prefix, suffix = file[:prefix], file[:suffix] # {prefix}{date}{suffix}
        file_handler = FileHandler.new(file[:dir] || file[:directory], prefix, suffix)
        file_handler.rotatable = file.key?(:rotatable) ? file[:rotatable] : file[:rotate]
        file_handler.buffer_size = file[:buffer_size] if file[:buffer_size]
        format = file.key?(:format) ? file[:format] : logging[:format]
        file_handler.formatter = web_app_formatter(format) # nil uses default
        logger.add_handler(file_handler)
      end
      logger
    end

    protected

    def self.console_formatter
      MessageFormatter.new
    end

    def self.web_app_formatter(format = nil)
      # format used by Rails "2012-06-13 16:42:21 +0200"
      DefaultFormatter.new(format.nil? ? 'yyyy-MM-dd HH:mm:ss Z' : format)
    end

    private

    def self.parse_log_level(log_level, default = nil)
      log_level = log_level && log_level.to_s.upcase
      unless JUL::Level.constants.find { |level| level.to_s == log_level }
        case log_level
        when 'ERROR' then log_level = 'SEVERE'
        when 'WARN' then log_level = 'WARNING'
        when 'DEBUG' then log_level = 'FINE'
        end # try mapping common level names to JUL names
        log_level ||= default ? default.to_s.upcase : nil
      end
      JUL::Level.parse(log_level) if log_level
    rescue => e
      JUL::Logger.getLogger('').warning "Failed to parse log level #{log_level.inspect} (#{e})"
      JUL::Level.const_get(default)
    end

    def self.set_log_level(logger, level)
      logger.level = level; LogFactory.getLog(logger.name)
    end

    def self.silence_tomcat_loggers
      # org.apache.coyote.http11.Http11Protocol   INFO: Initializing ProtocolHandler ["http-bio-3000"]
      # org.apache.catalina.core.StandardService  INFO: Starting service Tomcat
      # org.apache.catalina.core.StandardEngine   INFO: Starting Servlet Engine: Apache Tomcat/7.0.27
      # org.apache.catalina.startup.ContextConfig INFO: No global web.xml found
      # org.apache.coyote.http11.Http11Protocol   INFO: Starting ProtocolHandler ["http-bio-3000"]
      level = JUL::Level::WARNING
      logger_names = [
        'org.apache.catalina.core.StandardService',
        'org.apache.catalina.core.StandardEngine',
        'org.apache.catalina.startup.ContextConfig',
        # tldConfig.noTldSummary=At least one JAR was scanned for TLDs yet contained no TLDs.
        'org.apache.catalina.startup.TldConfig',
      ]
      for name in logger_names
        logger = JUL::Logger.getLogger(name)
        set_log_level(logger, level) if logger
      end
    end

    def self.web_app_context_param(web_app, context, name)
      context.find_parameter(name) || web_app.web_xml_context_param(name)
    end

    JUL::ConsoleHandler.class_eval do
      field_accessor :sealed rescue nil
      field_writer :writer rescue nil
    end

    def self.new_console_handler(stream)
      handler = JUL::ConsoleHandler.new # sets output stream to System.err
      handler.writer = nil if handler.respond_to?(:writer=) # avoid writer.close
      if handler.respond_to?(:sealed) && handler.sealed
        handler.sealed = false # avoid manager security checks
        handler.setOutputStream(stream) # closes previous writer if != null
        handler.sealed = true
      else
        handler.setOutputStream(stream)
      end
      handler
    end

    # @private
    FileHandler = Java::RbTrinidadLogging::FileHandler

  end
end
