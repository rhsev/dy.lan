# frozen_string_literal: true

require 'cgi'

module Dylan
  # ANSI → HTML for text that came from a terminal (widget tiles, script output).
  #
  # Covers what shell scripts actually emit: SGR 30–37, 40–47, 90–97, bold and
  # reset. 256-colour and truecolor sequences are **stripped, not translated** —
  # a wrong colour is worse than none, and nothing in the widget vocabulary
  # needs them. Every other escape sequence (cursor moves, erase-line) is
  # dropped as well.
  #
  # Carriage returns are treated the way a terminal shows them: within a line,
  # what comes after the last `\r` wins. That is what makes `pv`-style progress
  # output readable instead of a smear of overwritten fragments.
  #
  #   Dylan::Ansi.to_html("\e[32mdone\e[0m")
  #   # => "<span class=\"ansi-fg-green\">done</span>"
  #
  # No HTTP, no plugin state — testable on its own (test/ansi_test.rb).
  module Ansi
    COLORS = %w[black red green yellow blue magenta cyan white].freeze

    # SGR parameter → what it changes. Anything not in here is ignored.
    RESET  = 0
    BOLD   = 1
    NOBOLD = 22

    SGR_RE   = /\e\[([0-9;]*)m/
    # Every CSI sequence whose final byte is not "m", plus OSC strings, the
    # short two-character escapes, and a sequence cut off by the end of input.
    OTHER_RE = /\e\[[0-9;?]*[@-ln-~]|\e\][^\a\e]*(?:\a|\e\\)|\e[^\[\]]|\e[\[\]]?[0-9;?]*\z/

    class << self
      def to_html(text)
        return '' if text.nil?

        html  = +''
        state = { fg: nil, bg: nil, bold: false }
        open  = false

        scan(text.to_s) do |kind, value|
          case kind
          when :text
            next if value.empty?
            unless open || default?(state)
              html << span_tag(state)
              open = true
            end
            html << CGI.escape_html(value)
          when :sgr
            if open
              html << '</span>'
              open = false
            end
            apply(state, value)
          end
        end

        html << '</span>' if open
        html
      end

      private

      # Yields [:text, str] and [:sgr, params] in document order, with all
      # non-SGR escapes and overwritten line fragments already removed.
      def scan(text)
        pos = 0
        text = text.gsub(OTHER_RE, '')
        while (match = SGR_RE.match(text, pos))
          yield :text, collapse_cr(text[pos...match.begin(0)])
          yield :sgr, match[1]
          pos = match.end(0)
        end
        yield :text, collapse_cr(text[pos..] || '')
      end

      # A carriage return rewrites the current line — keep the last write only.
      # Newlines survive; the tile renders them with white-space: pre-wrap.
      def collapse_cr(chunk)
        return chunk unless chunk.include?("\r")
        chunk.split("\n", -1).map { |line| line.split("\r").last.to_s }.join("\n")
      end

      def apply(state, params)
        codes = params.to_s.split(';').map { |c| c.empty? ? 0 : c.to_i }
        codes = [RESET] if codes.empty?

        until codes.empty?
          code = codes.shift
          case code
          when RESET       then state.merge!(fg: nil, bg: nil, bold: false)
          when BOLD        then state[:bold] = true
          when NOBOLD      then state[:bold] = false
          when 30..37      then state[:fg] = COLORS[code - 30]
          when 39          then state[:fg] = nil
          when 40..47      then state[:bg] = COLORS[code - 40]
          when 49          then state[:bg] = nil
          when 90..97      then state[:fg] = "bright-#{COLORS[code - 90]}"
          when 100..107    then state[:bg] = "bright-#{COLORS[code - 100]}"
          when 38, 48      then drop_extended(codes)
          end
        end
      end

      # 38/48 introduce 5;<n> (256 colours) or 2;<r>;<g>;<b> (truecolor).
      # Swallow their arguments so the numbers cannot be mistaken for codes.
      def drop_extended(codes)
        case codes.first
        when 5 then codes.shift(2)
        when 2 then codes.shift(4)
        end
      end

      def default?(state)
        state[:fg].nil? && state[:bg].nil? && !state[:bold]
      end

      def span_tag(state)
        classes = []
        classes << "ansi-fg-#{state[:fg]}" if state[:fg]
        classes << "ansi-bg-#{state[:bg]}" if state[:bg]
        classes << 'ansi-bold'             if state[:bold]
        %(<span class="#{classes.join(' ')}">)
      end
    end
  end
end
