# frozen_string_literal: true

require "spec_helper"

class WeatherTool < PatientHttp::LLM::Tool
  description "Get the current weather for a location"
  param :location, type: "string", desc: "City name"
  param :units, type: "string", desc: "Temperature units"

  def execute(location:, units: "celsius")
    "Weather in #{location} (#{units})"
  end
end

class MyCustomCalculator < PatientHttp::LLM::Tool
  description "Perform calculations"
  param :expression, type: "string", desc: "Math expression"

  def execute(expression:)
    expression
  end
end

RSpec.describe PatientHttp::LLM::Tool do
  let(:weather_tool) { WeatherTool.new }
  let(:calc_tool) { MyCustomCalculator.new }

  describe "#name" do
    it "derives name from class name, removing Tool suffix" do
      expect(weather_tool.name).to eq("weather")
    end

    it "converts CamelCase to snake_case" do
      expect(calc_tool.name).to eq("my_custom_calculator")
    end
  end

  describe "#description" do
    it "returns the class-level description" do
      expect(weather_tool.description).to eq("Get the current weather for a location")
    end
  end

  describe "#parameters" do
    it "returns OpenAI-format JSON schema" do
      params = weather_tool.parameters
      expect(params[:type]).to eq("object")
      expect(params[:properties]["location"]).to eq({type: "string", description: "City name"})
      expect(params[:properties]["units"]).to eq({type: "string", description: "Temperature units"})
      expect(params[:required]).to eq(["location", "units"])
    end
  end

  describe "#call" do
    it "converts string keys to symbols and delegates to execute" do
      result = weather_tool.call({"location" => "NYC", "units" => "fahrenheit"})
      expect(result).to eq("Weather in NYC (fahrenheit)")
    end
  end

  describe "#halt" do
    it "returns a Halt instance" do
      result = weather_tool.halt("Done!")
      expect(result).to be_a(PatientHttp::LLM::Tool::Halt)
      expect(result.content).to eq("Done!")
    end
  end
end
