# frozen_string_literal: true

# Dylan Plugin: Jobs — tells you when a background job on a Milan agent ended.
#
#   GET /jobs/check   ask every agent for finished jobs nobody was told about,
#                     send one ntfy message per job, then acknowledge it
#
# A stream that loses its browser keeps running on the agent as a background
# job. The agent records how it ended; this route is what turns that record
# into a notification. It is called from cron once a minute (config/crontab).
#
# The route used to live in the Stage plugin as /stage/jobs/check. It is not
# part of the pad: nobody looks at it, it has no page, and it has to work
# while the pad is broken. The job *log* shown in the pad stays there.
#
# Config, in config/milan.yaml next to the agents the jobs come from:
#
#   milan:
#     ntfy:
#       url:   "https://ntfy.example.org"
#       topic: "jobs"
#
# Without it, jobs are acknowledged without a message, so they do not pile up
# as pending.

require 'json'
require 'uri'
require 'net/http'

class JobsPlugin < Dylan::Plugin
  pattern(%r{^/jobs/check$})
  timeout(10)
  config_file    'milan.yaml'
  config_section 'milan'

  # Per agent. A sleeping Mac does not refuse, it drops silently, and without
  # a limit of its own it would use up the budget of the agents after it.
  AGENT_TIMEOUT = 4

  def call(host, path, request)
    lines = agents.map { |name| Async { check_agent(name) } }
                        .flat_map(&:wait)
    Dylan::Response.text(lines.empty? ? 'no pending jobs' : lines.join("\n"))
  end

  private

  # One line per job, or one line saying why the agent could not be asked.
  def check_agent(agent)
    # The limit covers the question only. Notifying and acknowledging run
    # outside it: cut off between the two, a job would be announced twice.
    jobs = within(AGENT_TIMEOUT) { pending(agent) }
    jobs.map { |job| report(agent, job) }
  rescue Async::TimeoutError
    ["#{agent}: no answer within #{AGENT_TIMEOUT}s"]
  rescue => e
    ["#{agent}: error — #{e.message}"]
  end

  # Acknowledged only once the notification is out. A job whose message
  # failed stays pending and is tried again on the next run.
  def report(agent, job)
    ok  = job['exit_ok']
    msg = "#{ok ? '✓' : '✗'} #{job['script']} #{ok ? 'completed' : 'failed'} (#{agent})"
    return "#{msg} (ntfy failed, job stays pending)" unless notify(msg)

    acknowledge(agent, job['id'].to_s)
    msg
  end

  # ── The three things this plugin asks of Milan ─────────────────────────────

  def agents = Dylan::Milan.agents.keys

  def pending(agent)
    body = Dylan::Milan.get!(agent, '/jobs/pending').body
    JSON.parse(body.empty? ? '[]' : body)
  end

  def acknowledge(agent, id)
    Dylan::Milan.get(agent, "/jobs/ack/#{URI.encode_www_form_component(id)}")
  rescue StandardError
    nil  # still pending on the agent, so the next run announces it again
  end

  # True when the message went out, or when no ntfy is configured and there is
  # nothing to send. False when sending failed.
  def notify(msg)
    cfg = (config || {})['ntfy']
    return true unless cfg && !cfg['url'].to_s.strip.empty? && !cfg['topic'].to_s.strip.empty?

    uri  = URI("#{cfg['url'].chomp('/')}/#{cfg['topic']}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = (uri.scheme == 'https')
    http.open_timeout = 4
    http.read_timeout = 4
    req = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path)
    req['Title']        = 'Stage Job'   # unchanged from the Stage days; filters may key on it
    req['Content-Type'] = 'text/plain; charset=utf-8'
    req.body = msg
    response = http.request(req)
    return true if response.is_a?(Net::HTTPSuccess)

    warn "[Jobs] ntfy: HTTP #{response.code}"
    false
  rescue => e
    warn "[Jobs] ntfy: #{e.message}"
    false
  end
end
