# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientLLM::Schema do
  describe ".build" do
    it "builds an object schema from field declarations" do
      schema = described_class.build do
        field :summary, :string, "A short summary", required: true
        field :confidence, :number
      end

      expect(schema).to eq({
        "type" => "object",
        "properties" => {
          "summary" => {"type" => "string", "description" => "A short summary"},
          "confidence" => {"type" => "number"}
        },
        "required" => ["summary"]
      })
    end

    it "supports param as an alias for field" do
      schema = described_class.build do
        param :city, :string, required: true
      end

      expect(schema["properties"]).to eq({"city" => {"type" => "string"}})
      expect(schema["required"]).to eq(["city"])
    end

    it "builds arrays of primitives" do
      schema = described_class.build do
        field :tags, array: :string
      end

      expect(schema["properties"]["tags"]).to eq({"type" => "array", "items" => {"type" => "string"}})
    end

    it "builds enums" do
      schema = described_class.build do
        field :status, :string, enum: [:draft, :final]
      end

      expect(schema["properties"]["status"]).to eq({"type" => "string", "enum" => ["draft", "final"]})
    end

    it "builds nested objects from blocks" do
      schema = described_class.build do
        field :author, :object do
          field :name, :string, required: true
        end
      end

      expect(schema["properties"]["author"]).to eq({
        "type" => "object",
        "properties" => {"name" => {"type" => "string"}},
        "required" => ["name"]
      })
    end

    it "builds arrays of objects from blocks" do
      schema = described_class.build do
        field :stops, array: :object do
          field :city, :string
        end
      end

      expect(schema["properties"]["stops"]).to eq({
        "type" => "array",
        "items" => {"type" => "object", "properties" => {"city" => {"type" => "string"}}}
      })
    end

    it "treats a block with no type as an object" do
      schema = described_class.build do
        field :meta do
          field :key, :string
        end
      end

      expect(schema["properties"]["meta"]["type"]).to eq("object")
    end

    it "accepts a raw schema hash escape hatch" do
      schema = described_class.build do
        field :anything, {"type" => "string", "pattern" => "^a"}
      end

      expect(schema["properties"]["anything"]).to eq({"type" => "string", "pattern" => "^a"})
    end

    it "raises for an unknown type" do
      expect {
        described_class.build { field :bad, :decimal }
      }.to raise_error(ArgumentError, /Unknown type/)
    end

    it "raises when both a type and array: are given" do
      expect {
        described_class.build { field :bad, :string, array: :string }
      }.to raise_error(ArgumentError, /either a type or array:/)
    end

    it "raises when a field has no type, array, or block" do
      expect {
        described_class.build { field :bad }
      }.to raise_error(ArgumentError, /requires a type/)
    end
  end
end
