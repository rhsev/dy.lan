# frozen_string_literal: true

# ruby test/ansi_test.rb
#
# The ANSI renderer is the one piece of the board that is worth testing on its
# own: it takes untrusted terminal output and turns it into markup.

require 'minitest/autorun'
require_relative '../lib/ansi'

class AnsiTest < Minitest::Test
  def render(text) = Dylan::Ansi.to_html(text)

  def test_plain_text_passes_through
    assert_equal 'Backup läuft', render('Backup läuft')
    assert_equal '', render('')
    assert_equal '', render(nil)
  end

  def test_html_is_escaped
    assert_equal '&lt;script&gt;alert(1)&lt;/script&gt;', render('<script>alert(1)</script>')
    assert_equal '&amp; &quot;quoted&quot;', render('& "quoted"')
  end

  # The escaping has to survive inside a coloured span too — that is where a
  # naive implementation concatenates raw text after building the tag.
  def test_html_is_escaped_inside_colour
    assert_equal '<span class="ansi-fg-red">&lt;b&gt;</span>', render("\e[31m<b>\e[0m")
  end

  def test_foreground_colours
    assert_equal '<span class="ansi-fg-green">done</span>', render("\e[32mdone\e[0m")
    assert_equal '<span class="ansi-fg-red">fail</span>',   render("\e[31mfail\e[0m")
    assert_equal '<span class="ansi-fg-bright-blue">x</span>', render("\e[94mx\e[0m")
  end

  def test_background_and_bold
    assert_equal '<span class="ansi-bg-yellow">warn</span>', render("\e[43mwarn\e[0m")
    assert_equal '<span class="ansi-bold">loud</span>',      render("\e[1mloud\e[0m")
    assert_equal '<span class="ansi-fg-white ansi-bg-red ansi-bold">!</span>',
                 render("\e[37;41;1m!\e[0m")
  end

  def test_unclosed_sequence_is_closed
    assert_equal '<span class="ansi-fg-green">done</span>', render("\e[32mdone")
  end

  def test_state_carries_across_segments
    assert_equal '<span class="ansi-fg-green">a</span><span class="ansi-fg-green ansi-bold">b</span>',
                 render("\e[32ma\e[1mb")
  end

  def test_reset_variants
    assert_equal '<span class="ansi-fg-green">a</span>b', render("\e[32ma\e[mb")
    assert_equal '<span class="ansi-fg-green">a</span>b', render("\e[32ma\e[0mb")
    assert_equal '<span class="ansi-fg-green">a</span><span class="ansi-bg-blue">b</span>',
                 render("\e[32ma\e[39;44mb")
    assert_equal '<span class="ansi-bold">a</span>b', render("\e[1ma\e[22mb")
  end

  # 256-colour and truecolor are stripped rather than guessed at — including
  # their arguments, which must not be read back as codes of their own.
  def test_extended_colours_are_stripped
    assert_equal 'text', render("\e[38;5;208mtext\e[0m")
    assert_equal 'text', render("\e[38;2;255;128;0mtext\e[0m")
    assert_equal '<span class="ansi-bold">text</span>', render("\e[38;5;208;1mtext\e[0m")
  end

  def test_non_sgr_escapes_are_dropped
    assert_equal 'clean', render("\e[2K\e[1Gclean")
    assert_equal 'title', render("\e]0;window title\atitle")
    assert_equal '<span class="ansi-fg-green">ok</span>', render("\e[?25l\e[32mok\e[0m\e[?25h")
  end

  # pv writes progress by rewriting the line: only the last state should show.
  def test_carriage_return_keeps_last_write
    assert_equal '99%', render("10%\r50%\r99%")
    assert_equal "line1\n99%", render("line1\n10%\r99%")
    assert_equal '<span class="ansi-fg-green">99%</span>', render("\e[32m10%\r99%\e[0m")
  end

  def test_newlines_survive
    assert_equal "a\nb", render("a\nb")
  end

  # Nothing may leak out of a span: an unknown code must not produce a tag with
  # no classes, and a lone ESC must not survive into the markup.
  def test_unknown_codes_produce_no_markup
    assert_equal 'plain', render("\e[4mplain\e[0m")
    refute_includes render("\e[99mx"), '<span'
    refute_includes render("\e"), "\e"
  end
end
