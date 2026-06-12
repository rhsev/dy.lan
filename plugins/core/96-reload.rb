# frozen_string_literal: true

# Reload Plugin — Server-Restart auf Knopfdruck.
#
# `exit(0)` beendet den Ruby-Prozess; Docker's restart-policy bringt den
# Container wieder hoch. Während des Restarts (typisch 5-15s) ist Dylan
# offline.
#
# Die HTML-Response ist bewusst self-contained (Inline-Styles + Inline-JS).
# Während des Restarts wäre extern eingebundene CSS nicht erreichbar, daher
# keine `<link>`/`<script src>`-Referenzen. Das Polling-JS prüft alle Sekunde
# `/dylan/stats?format=json` und redirected nach /manage sobald der Server
# wieder antwortet.

class ReloadPlugin < Dylan::Plugin
  # (\?|$): Dylans path enthält den Query-String — mit ^/reload$ wäre
  # /reload?format=json ein 404 und der JSON-Zweig unerreichbar.
  pattern(%r{^/reload(\?|$)})

  def call(host, path, request)
    format = parse_query(request)['format']

    Thread.new do
      sleep 0.5  # Response Zeit zu senden geben
      puts "🔄 Server restart requested via /reload"
      exit(0)
    end

    if format == 'json'
      Dylan::Response.json({ status: 'restarting', message: 'Server will restart in 0.5 seconds' })
    else
      Dylan::Response.html(inline_html)
    end
  end

  private

  def parse_query(request)
    query_string = request.path.split('?', 2)[1] || ''
    query_string.split('&').each_with_object({}) do |pair, hash|
      key, value = pair.split('=', 2)
      hash[key] = value if key
    end
  end

  def inline_html
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <title>Restarting...</title>
        <style>
          body { font-family: sans-serif; margin: 40px; background: #f5f5f5; text-align: center; padding-top: 100px; }
          .message { background: white; max-width: 500px; margin: 0 auto; padding: 40px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
          .spinner { border: 4px solid #f3f3f3; border-top: 4px solid #4CAF50; border-radius: 50%; width: 40px; height: 40px; animation: spin 1s linear infinite; margin: 20px auto; }
          @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
          .status { margin-top: 20px; color: #666; font-size: 14px; }
        </style>
        <script>
          let attempts = 0;
          const maxAttempts = 30;
          function checkServer() {
            attempts++;
            fetch('/dylan/stats?format=json')
              .then(r => {
                if (r.ok) {
                  document.getElementById('status').textContent = 'Server is back online! Redirecting...';
                  setTimeout(() => window.location.href = '/manage', 500);
                } else { throw new Error('Not ready'); }
              })
              .catch(() => {
                if (attempts < maxAttempts) {
                  document.getElementById('status').textContent = 'Waiting for server... (' + attempts + 's)';
                  setTimeout(checkServer, 1000);
                } else {
                  document.getElementById('status').textContent = 'Server restart taking longer than expected. Please refresh manually.';
                }
              });
          }
          setTimeout(checkServer, 2000);
        </script>
      </head>
      <body>
        <div class="message">
          <h1>🔄 Restarting Server...</h1>
          <div class="spinner"></div>
          <p id="status" class="status">Server is restarting...</p>
        </div>
      </body>
      </html>
    HTML
  end
end
