require 'shrimp/base_middleware'

module Shrimp
  class InlineMiddleware < BaseMiddleware
    def render_as_pdf(env)
      # In this same request, get the HTML from the app, save to a temp file, and start PhantomJS
      # rendering that temp HTML in the same process.
      responder = Responder.new(@app, env, @options, @request)
      responder.respond
    end

    private

    # Based on http://viget.com/extend/refactoring-patterns-the-rails-middleware-response-handler
    # So we can use instance variables without having to worry about them being shared for all
    # requests (since only one instance of the middleware class is created).
    class Responder < Shrimp::BaseMiddleware::Responder
      def initialize(app, env, options, request)
        @app = app
        @env = env
        @options = options
        @request = request
      end

      attr_reader :phantom

      def respond
        render_inline_html_to_pdf
        return phantomjs_error_response if phantom.error?

        body = pdf_body()
        headers = pdf_headers(body, filename: html_headers['X-Pdf-Filename'])
        [200, headers, [body]]
      end

      def render_inline_html_to_pdf
        log_render_pdf_start
        Phantom.new(html_file_url, @options, {}).tap do |phantom|
          @phantom = phantom
          phantom.to_file(render_to)
          log_render_pdf_completion
        end
      end

      def html_file_url
        file = html_file
        "file://#{file.path}"
      end

      # Creates a random file name in the temp dir.
      def html_file_name
        @html_file_name ||= Shrimp::Phantom.default_file_name('html')
      end

      def html_file
        File.new(html_file_name, 'w').tap {|file|
          file.write html
        }
      end

      def html
        status, headers, response = html_response
        response.body
      end

      def html_headers
        status, headers, response = html_response
        headers
      end

      def html_response
        @html_response ||= (
          @env.each do |key, value|
            if value =~ %r<\.pdf(\?|$)>
              @env[key].sub!(%r<\.pdf(\?|$)>, '\1')
            end
          end
          @env['PhantomJS'] = 'Shrimp::InlineMiddleware'
          @app.call(@env)
        )
      end

      def phantomjs_error_response
        headers = {'Content-Type' => 'text/html'}
        if phantom.page_load_error?
          status_code = phantom.page_load_status_code
          headers['Location'] = phantom.redirect_to if phantom.redirect?
        else
          status_code = 500
        end
        [status_code, headers, [phantom.error]]
      end
    end
  end
end
