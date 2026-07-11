# frozen_string_literal: true

module PatientLLM
  # A minimal JSON Schema builder used by the {Agent} DSL for tool parameters
  # and structured output. It deliberately covers only the common cases —
  # primitive types, enums, required fields, arrays, and nested objects. Pass
  # a raw JSON Schema hash anywhere a schema is accepted for anything beyond
  # that.
  #
  # @example
  #   schema = PatientLLM::Schema.build do
  #     field :summary, :string, "A short summary", required: true
  #     field :confidence, :number
  #     field :tags, array: :string
  #     field :status, :string, enum: ["draft", "final"]
  #     field :author, :object do
  #       field :name, :string, required: true
  #     end
  #   end
  class Schema
    # JSON Schema primitive type names accepted by {#field}.
    TYPES = %w[string number integer boolean object array null].freeze

    class << self
      # Build a JSON Schema object hash from a block of {#field} declarations.
      #
      # @yield the block declaring fields, evaluated in the builder's context
      # @return [Hash] the JSON Schema hash
      def build(&block)
        builder = new
        builder.instance_eval(&block) if block
        builder.to_h
      end
    end

    def initialize
      @properties = {}
      @required = []
    end

    # Declare a field on the object schema.
    #
    # @param name [Symbol, String] the field name
    # @param type [Symbol, String, Hash, nil] the JSON Schema type, or a raw
    #   JSON Schema hash used as-is
    # @param description [String, nil] a description of the field
    # @param required [Boolean] whether the field is required
    # @param enum [Array, nil] allowed values for the field
    # @param array [Symbol, String, Hash, nil] declare an array whose items are
    #   this type (or raw schema hash); use with a block for arrays of objects
    # @yield an optional block declaring a nested object's fields (with
    #   type :object or array: :object)
    # @return [Hash] the field's schema
    def field(name, type = nil, description = nil, required: false, enum: nil, array: nil, &block)
      raise ArgumentError, "pass either a type or array:, not both" if type && array

      property =
        if array
          {"type" => "array", "items" => item_schema(array, &block)}
        elsif type
          item_schema(type, &block)
        elsif block
          item_schema(:object, &block)
        else
          raise ArgumentError, "field #{name.inspect} requires a type, array:, or a block"
        end

      property["description"] = description.to_s if description
      property["enum"] = PromptBuilder.jsonify(enum) if enum

      @properties[name.to_s] = property
      @required << name.to_s if required
      property
    end
    alias_method :param, :field

    # The JSON Schema hash for the declared fields.
    #
    # @return [Hash]
    def to_h
      schema = {"type" => "object", "properties" => @properties}
      schema["required"] = @required unless @required.empty?
      schema
    end

    private

    def item_schema(type, &block)
      return PromptBuilder.jsonify(type) if type.is_a?(Hash)

      type = type.to_s
      unless TYPES.include?(type)
        raise ArgumentError, "Unknown type: #{type.inspect}. Valid types: #{TYPES.join(", ")} or a raw JSON Schema hash"
      end

      if type == "object" && block
        nested = self.class.new
        nested.instance_eval(&block)
        nested.to_h
      else
        {"type" => type}
      end
    end
  end
end
