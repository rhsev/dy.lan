# frozen_string_literal: true

# ruby test/stats_test.rb
#
# /dylan/stats says how much memory the server holds, so growth can be read
# from outside the container.

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require_relative '../lib/plugin'
require_relative '../lib/response'
require_relative '../lib/router'
require_relative '../plugins/core/90-maintenance'

StatsRequest = Struct.new(:path)

class StatsTest < Minitest::Test
  def setup
    @plugin = MaintenancePlugin.new
    @plugin.router = Dylan::Router.new(Dir.mktmpdir)
  end

  def stats
    response = @plugin.call('dy.lan', '/dylan/stats', StatsRequest.new('/dylan/stats?format=json'))
    JSON.parse(response.body.join)
  end

  def test_names_the_ruby_and_the_heap
    assert_equal RUBY_VERSION, stats['ruby']
    assert_operator stats['heap_pages'], :>, 0
  end

  # /proc exists on Linux only; elsewhere the field is there and empty.
  def test_memory_is_a_number_where_the_kernel_tells
    assert stats.key?('rss_kb')
    if File.exist?('/proc/self/status')
      assert_operator stats['rss_kb'], :>, 1000
    else
      assert_nil stats['rss_kb']
    end
  end

  def test_text_form_survives_a_missing_figure
    response = @plugin.call('dy.lan', '/dylan/stats', StatsRequest.new('/dylan/stats'))
    assert_includes response.body.join, 'Uptime'
  end
end
