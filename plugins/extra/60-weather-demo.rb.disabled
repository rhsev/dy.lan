# frozen_string_literal: true

require 'net/http'
require 'json'

# Weather Demo Plugin
# Shows how external API calls work (parallel thanks to Async!)
#
# Example: /weather/Berlin
#
# NOTE: In production you would use async-http for API calls,
# but Net::HTTP also works (Async yields control during I/O)

class WeatherDemoPlugin < Dylan::Plugin
  pattern(%r{^/weather/(.+)$})
  timeout(3.0)  # Weather API needs 3 seconds for external calls

  def call(host, path, request)
    match = path.match(%r{^/weather/(.+)$})
    city = match[1]

    # Demo: Simulate slow API call (2 seconds)
    # In production this would be an HTTP request to a weather API
    # Use Async::Task.current.sleep to yield CPU to other requests
    Async::Task.current.sleep(2)

    # Return fake data
    data = {
      city: city,
      temperature: rand(15..25),
      condition: ['Sunny', 'Cloudy', 'Rainy'].sample,
      timestamp: Time.now.iso8601,
      note: "This is a demo. Real plugin would call weather API."
    }

    Dylan::Response.json(data)
  end
end
