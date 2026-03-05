# frozen_string_literal: true

class WeatherTool < RubyLLM::Tool
  description "Get the current weather for a city"

  param :city, desc: "The city name"

  def execute(city:)
    conditions = ["sunny", "partly cloudy", "overcast", "rainy", "foggy"].sample
    temp = rand(45..95)
    humidity = rand(20..90)

    "#{temp}°F and #{conditions} in #{city} (humidity: #{humidity}%)"
  end
end
