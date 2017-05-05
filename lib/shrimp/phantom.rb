require 'uri'
require 'json'
require 'shellwords'

module Shrimp
  class NoExecutableError < StandardError
    def initialize
      msg = "No phantomjs executable found at #{Shrimp.config.phantomjs}\n"
      msg << ">> Please install phantomjs - http://phantomjs.org/download.html"
      super(msg)
    end
  end

  class ImproperSourceError < StandardError
    def initialize(msg = nil)
      super("Improper Source: #{msg}")
    end
  end

  class RenderingError < StandardError
    def initialize(msg = nil)
      super("Rendering Error: #{msg}")
    end
  end

  class Phantom
    attr_accessor :source, :configuration, :outfile
    attr_reader :options, :cookies, :result, :error, :response, :response_headers
    SCRIPT_FILE = File.expand_path('../rasterize.js', __FILE__)

    # Public: Runs the phantomjs binary
    #
    # Returns the stdout output from phantomjs
    def run
      @error  = nil
      puts "Running command: #{cmd}" if options[:debug]
      @result = `#{cmd}`
      if match = @result.match(response_line_regexp)
        @response = JSON.parse match[1]
        @response_headers = @response['headers'].inject({}) {|hash, header|
          hash[header['name']] = header['value']; hash
        }
        @result.gsub! response_line_regexp, ''
      end
      unless $?.exitstatus == 0
        @error  = @result.chomp
        @result = nil
      end
      @result
    end

    def run!
      run.tap {
        raise RenderingError.new(error) if error?
      }
    end

    def response_line_regexp
      /^response: (.*)$\n?/
    end
    def redirect?
      page_load_status_code == 302
    end
    def redirect_to
      return unless redirect?
      response['redirectURL'] if response
    end

    def error?
      !!error
    end

    def match_page_load_error
      error.to_s.match /^.* \(HTTP (null|\S+)\).*/
    end
    def page_load_error?
      !!match_page_load_error
    end
    def page_load_status_code
      if match = match_page_load_error
        status_code = match[1].to_s
        if status_code =~ /\A\d+\Z/
          status_code.to_i
        else
          status_code
        end
      end
    end

    # Public: Returns the arguments for the PhantomJS rasterize command as a shell-escaped string
    def cmd
      Shellwords.join cmd_array
    end

    # Public: Returns the arguments for the PhantomJS rasterize command as an array
    def cmd_array
      cookie_file                       = dump_cookies
      format, zoom, margin, orientation = options[:format], options[:zoom], options[:margin], options[:orientation]
      rendering_time, timeout           = options[:rendering_time], options[:rendering_timeout]
      viewport_width, viewport_height   = options[:viewport_width], options[:viewport_height]
      max_redirect_count                = options[:max_redirect_count]
      @outfile                          ||= "#{options[:tmpdir]}/#{Digest::MD5.hexdigest((Time.now.to_i + rand(9001)).to_s)}.pdf"
      command_config_file               = "--config=#{options[:command_config_file]}"
      [
        Shrimp.configuration.phantomjs,
        command_config_file,
        SCRIPT_FILE,
        @source.to_s,
        @outfile,
        format,
        zoom,
        margin,
        orientation,
        cookie_file,
        rendering_time,
        timeout,
        viewport_width,
        viewport_height,
        max_redirect_count
      ].map(&:to_s)
    end

    # Public: initializes a new Phantom Object
    #
    # url_or_file             - The url of the html document to render
    # options                 - a hash with options for rendering
    #   * format              - the paper format for the output eg: "5in*7.5in", "10cm*20cm", "A4", "Letter"
    #   * zoom                - the viewport zoom factor
    #   * margin              - the margins for the pdf
    #   * command_config_file - the path to a json configuration file for command-line options
    # cookies                 - hash with cookies to use for rendering
    # outfile                 - optional path for the output file a Tempfile will be created if not given
    #
    # Returns self
    def initialize(url_or_file, options = { }, cookies={ }, outfile = nil)
      @source  = Source.new(url_or_file)
      @options = Shrimp.config.to_h.merge(options)
      @cookies = cookies
      @outfile = File.expand_path(outfile) if outfile
      raise NoExecutableError.new unless File.exists?(Shrimp.config.phantomjs)
    end

    # Public: renders to pdf
    # path  - the destination path defaults to outfile
    #
    # Returns the path to the pdf file
    def to_pdf(path=nil)
      @outfile = File.expand_path(path) if path
      self.run
      @outfile
    end

    # Public: renders to pdf
    # path  - the destination path defaults to outfile
    #
    # Returns a File Handle of the Resulting pdf
    def to_file(path=nil)
      self.to_pdf(path)
      File.new(@outfile)
    end

    # Public: renders to pdf
    # path  - the destination path defaults to outfile
    #
    # Returns the binary string of the pdf
    def to_string(path=nil)
      File.open(self.to_pdf(path)).read
    end

    def to_pdf!(path=nil)
      @outfile = File.expand_path(path) if path
      self.run!
      @outfile
    end

    def to_file!(path=nil)
      self.to_pdf!(path)
      File.new(@outfile)
    end

    def to_string!(path=nil)
      File.open(self.to_pdf!(path)).read
    end

    private

    def dump_cookies
      host = @source.url? ? URI::parse(@source.to_s).host : "/"
      json = @cookies.inject([]) { |a, (k, v)| a.push({ :name => k, :value => v, :domain => host }); a }.to_json
      File.open("#{options[:tmpdir]}/#{rand}.cookies", 'w') { |f| f.puts json; f }.path
    end
  end
end
