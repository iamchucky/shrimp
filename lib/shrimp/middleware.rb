require 'shrimp/base_middleware'

module Shrimp
  class Middleware < BaseMiddleware
    def initialize(app, options = { }, conditions = { })
      super
      @options[:polling_interval] ||= 1
      @options[:polling_offset]   ||= 1
      @options[:cache_ttl]        ||= 1
      @options[:request_timeout]  ||= @options[:polling_interval] * 10
    end

    def render_as_pdf(env)
      if already_rendered? && (up_to_date?(@options[:cache_ttl]) || @options[:cache_ttl] == 0)
        if File.size(render_to) == 0
          delete_tmp_files
          remove_rendering_flag
          return error_response
        end
        return ready_response if env['HTTP_X_REQUESTED_WITH']
        body = pdf_body()
        delete_tmp_files if @options[:cache_ttl] == 0
        remove_rendering_flag
        headers = pdf_headers(body)
        [200, headers, [body]]
      else
        if rendering_in_progress?
          if rendering_timed_out?
            remove_rendering_flag
            error_response
          else
            reload_response(@options[:polling_interval])
          end
        else
          delete_tmp_files if already_rendered?
          set_rendering_flag
          # Start PhantomJS rendering in a separate thread and then immediately render a web page
          # that continuously reloads (polls) until the rendering is complete.
          # Using Thread.new instead of Process::detach fork because Process fork will cause
          # database disconnection when the forked process ended
          Thread.new {
            render_pdf
          }
          reload_response(@options[:polling_offset])
        end
      end
    end

    private

    def already_rendered?
      File.exists?(render_to_done) && File.exists?(render_to)
    end

    def up_to_date?(ttl = 30)
      (Time.now - File.new(render_to).mtime) <= ttl
    end

    def delete_tmp_files
      File.delete(render_to)
      File.delete(render_to_done)
    end

    def remove_rendering_flag
      @request.session["phantom-rendering"] ||={ }
      @request.session["phantom-rendering"].delete(render_to)
    end

    def set_rendering_flag
      @request.session["phantom-rendering"]            ||={ }
      @request.session["phantom-rendering"][render_to] = Time.now
    end

    def rendering_started_at
      @request.session["phantom-rendering"][render_to].to_time
    end

    def rendering_timed_out?
      Time.now - rendering_started_at > @options[:request_timeout]
    end

    def rendering_in_progress?
      @request.session["phantom-rendering"] ||={ }
      !!@request.session["phantom-rendering"][render_to]
    end


    def reload_response(interval=1)
      body = <<-HTML.gsub(/[ \n]+/, ' ').strip
          <html>
          <head>
        </head>
          <body onLoad="setTimeout(function(){ window.location.reload()}, #{interval * 1000});">
          <h2>Preparing PDF file.  Please wait... </h2>
          </body>
        </ html>
      HTML
      headers                   = { }
      headers["Content-Length"] = body.size.to_s
      headers["Content-Type"]   = "text/html"
      headers["Retry-After"]    = interval.to_s

      [503, headers, [body]]
    end

    def ready_response
      body = <<-HTML.gsub(/[ \n]+/, ' ').strip
        <html>
        <head>
        </head>
        <body>
        <a href="#{@request.path}">PDF file ready here</a>
        </body>
      </ html>
      HTML
      headers                   = { }
      headers["Content-Length"] = body.size.to_s
      headers["Content-Type"]   = "text/html"
      [200, headers, [body]]
    end

    def error_response
      body = <<-HTML.gsub(/[ \n]+/, ' ').strip
        <html>
        <head>
        </head>
        <body>
        <h2>Sorry, the request timed out.</h2>
        </body>
      </ html>
      HTML
      headers                   = { }
      headers["Content-Length"] = body.size.to_s
      headers["Content-Type"]   = "text/html"
      [504, headers, [body]]
    end
  end
end
