# frozen_string_literal: true

class WeatherTool
  CONDITIONS = ["Sunny", "Cloudy", "Rainy", "Snowy", "Partly Cloudy", "Foggy", "Windy"].freeze

  def self.call(city:, state: nil, country: nil)
    temperature = rand(32..95)
    condition = CONDITIONS.sample
    humidity = rand(20..90)
    wind_speed = rand(0..25)

    {
      location: [city, state, country].compact.join(", "),
      condition: condition,
      temperature_f: temperature,
      humidity_percent: humidity,
      wind_speed_mph: wind_speed,
      forecast: "#{condition} with a high of #{temperature}°F"
    }
  end
end
