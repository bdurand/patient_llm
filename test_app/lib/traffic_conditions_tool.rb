# frozen_string_literal: true

class TrafficConditionsTool
  CONGESTION_LEVELS = ["light", "moderate", "heavy", "gridlock"].freeze
  ROAD_CONDITIONS = ["clear", "wet", "icy", "construction"].freeze
  AVERAGE_SPEEDS = 25..65

  class << self
    # Return a mock traffic conditions report for a given location.
    #
    # @param city [String] the city name
    # @param state [String] the state or province (optional)
    # @param country [String] the country (optional)
    # @param time [String] the time of day to check (optional)
    # @return [Hash] a mock traffic report
    def call(city:, state: nil, country: nil, time: nil)
      location = [city, state, country].compact.join(", ")

      {
        location: location,
        time: time || "now",
        congestion: CONGESTION_LEVELS.sample,
        average_speed_mph: rand(AVERAGE_SPEEDS),
        road_condition: ROAD_CONDITIONS.sample,
        incidents: rand(0..3),
        estimated_delay_minutes: rand(0..45)
      }
    end
  end
end
