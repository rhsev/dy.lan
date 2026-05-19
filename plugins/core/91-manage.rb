# frozen_string_literal: true

# ManageStage — Stage-Instance für die Dylan-Verwaltung.
#
# Routet unter /manage und ruft intern die Maintenance-Endpoints (/dylan/routes,
# /dylan/stats, ...) auf. Diese liefern Markdown-Text, das Stage in seiner
# Output-Box anzeigt.
#
# Der direkte Zugriff auf /dylan/* und /dylan/reload bleibt parallel erreichbar —
# Reload braucht seine eigene HTML-Page mit Polling-JS, die nicht ins Stage-
# Panel passt.

class ManageStage < StageBase
  pattern         %r{^/manage(/|\?|$)}
  url_prefix      '/manage'
  config_file     'manage.yaml'
  config_section  'stage'
end
