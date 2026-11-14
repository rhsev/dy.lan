# frozen_string_literal: true

require 'json'
require_relative 'milan'

module Dylan
  # Milan for tests: no agent, no network. A test says what Milan answers and
  # can read back what the plugin asked for.
  #
  #   require_relative '../lib/milan_double'
  #
  #   def setup    = @milan = Dylan::MilanDouble.use
  #   def teardown = Dylan::MilanDouble.reset
  #
  #   @milan.respond(body: [{ 'target' => 'copy' }])           # any agent, any path
  #   @milan.respond(path: '/jobs/pending', agent: 'book', status: 404, body: 'nope')
  #   @milan.respond(path: %r{^/album/}, delay: 2)             # a slow answer
  #   @milan.respond(error: Dylan::Milan::UnreachableError.new('mini', 'refused'))
  #   @milan.respond(path: '/stream/counter', chunks: ["data: 1\n\n", "data: 2\n\n"])
  #
  #   @milan.calls   # => [[:get, 'mini', '/widgets'], ...]
  #
  # The rule added last wins; a request no rule matches gets an empty 200.
  # A body that is not a String is sent as JSON. An agent that is not in
  # `agents` raises UnknownAgentError, as the real client does.
  #
  # While a double is in use it answers `agents`, `get`, `post` and `stream`
  # of Dylan::Milan — and with them `get!`, `post!`, `proxy_sse` and
  # `health_check`, which are built on those. After `reset`, Dylan::Milan is
  # itself again. One double per process is enough: test files that each
  # prepend a stub of their own get in each other's way when they run together.
  class MilanDouble
    DEFAULT_AGENTS = { 'mini' => 'http://mini.test:8080', 'book' => 'http://book.test:8080' }.freeze

    Rule = Struct.new(:path, :agent, :status, :body, :headers, :error, :delay, :chunks) do
      def match?(for_agent, for_path)
        (agent.nil? || agent == for_agent) && (path.nil? || path === for_path)
      end
    end

    class << self
      attr_reader :current

      def use(agents: DEFAULT_AGENTS)
        Dylan::Milan.singleton_class.prepend(Hook) unless Dylan::Milan.singleton_class.include?(Hook)
        @current = new(agents)
      end

      def reset
        @current = nil
      end
    end

    # Sits in front of Dylan::Milan and steps aside when no double is in use.
    module Hook
      def agents
        (double = MilanDouble.current) ? double.agents : super
      end

      def get(agent, path)
        (double = MilanDouble.current) ? double.request(:get, agent, path) : super
      end

      def post(agent, path, body, **options)
        (double = MilanDouble.current) ? double.request(:post, agent, path, body) : super
      end

      def stream(agent, path, &block)
        (double = MilanDouble.current) ? double.stream(agent, path, &block) : super
      end
    end

    attr_reader :calls
    attr_accessor :agents

    def initialize(agents)
      @agents = agents.dup
      @rules  = []
      @calls  = []
    end

    def respond(path: nil, agent: nil, status: 200, body: '', headers: {}, error: nil, delay: nil, chunks: nil)
      @rules.unshift(Rule.new(path, agent, status, body, headers, error, delay, chunks))
      self
    end

    # What was sent with the last POST to this path (or the last POST at all).
    def posted(path = nil)
      @calls.reverse.find { |verb, _agent, p, _body| verb == :post && (path.nil? || p == path) }&.last
    end

    def request(verb, agent, path, payload = nil)
      rule = answer_for(verb, agent, path, payload)
      body = rule.body.is_a?(String) ? rule.body : JSON.generate(rule.body)
      Dylan::Milan::Response.new(rule.status, rule.headers, body)
    end

    def stream(agent, path)
      rule = answer_for(:stream, agent, path)
      unless rule.status == 200
        raise Dylan::Milan::UnreachableError.new(agent, "HTTP #{rule.status}: #{rule.body.to_s.strip}")
      end

      (rule.chunks || [rule.body.to_s]).each { |chunk| yield chunk }
    end

    private

    def answer_for(verb, agent, path, payload = nil)
      @calls << (payload.nil? ? [verb, agent, path] : [verb, agent, path, payload])
      raise Dylan::Milan::UnknownAgentError.new(agent) unless @agents.key?(agent.to_s)

      rule = @rules.find { |r| r.match?(agent.to_s, path) } || Rule.new(nil, nil, 200, '', {})
      sleep(rule.delay) if rule.delay   # yields to the reactor inside a task
      raise rule.error if rule.error

      rule
    end
  end
end
