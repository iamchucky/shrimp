require 'shrimp/base_middleware'

module Shrimp
  class InlineMiddleware < BaseMiddleware
    def render_as_pdf(env)
      # In this same request, get the HTML from the app, save to a temp file, and start PhantomJS
      # rendering that temp HTML in the same process.
      render_inline_html_to_pdf html_file_url(html(env))
      return phantomjs_error_response if phantom.error?

      body = pdf_body()
      headers = pdf_headers(body, filename: @phantom.response_headers['X-Pdf-Filename'])
      [200, headers, [body]]
    end

    attr_reader :phantom

    private

    def html_file_url(html)
      file = html_file(html)
      "file://#{file.path}"
    end

    # TODO: add Responder class like in
    # http://viget.com/extend/refactoring-patterns-the-rails-middleware-response-handler
    # so we can use instance variables
    def html_file_name
      # @html_file_name ||=
      "#{Shrimp.config.to_h[:tmpdir]}/#{self.class.name}-#{Digest::MD5.hexdigest((Time.now.to_i + rand(9001)).to_s)}.html"
    end

    def html_file(html)
      File.new(html_file_name, 'w').tap {|file|
        file.write html
      }
    end

    def html(env)
      status, headers, response = html_response(env)
      response.body
    end

    def html_response(env)
      env.each do |key, value|
        if value =~ %r<\.pdf(\?|$)>
          env[key].sub!(%r<\.pdf(\?|$)>, '\1')
        end
      end
      env['PhantomJS'] = 'Shrimp::InlineMiddleware'
      @app.call(env)
    end

    def render_inline_html_to_pdf(html_file_url)
      log_render_pdf_start
      Phantom.new(html_file_url, @options, @request.cookies).tap do |phantom|
        @phantom = phantom
        phantom.to_file(render_to)
        log_render_pdf_completion
      end
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
