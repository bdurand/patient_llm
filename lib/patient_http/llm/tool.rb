# frozen_string_literal: true

module PatientHttp
  module LLM
    # Base class for LLM tools. Subclass and define parameters using the DSL.
    #
    # @example
    #   class WeatherTool < PatientHttp::LLM::Tool
    #     description "Get the current weather for a location"
    #     param :location, type: "string", desc: "City name"
    #
    #     def execute(location:)
    #       # fetch weather...
    #     end
    #   end
    class Tool
      # Returned from #call when a tool wants to halt the conversation.
      class Halt
        attr_reader :content

        def initialize(content)
          @content = content
        end
      end

      class << self
        # Set or get the tool description.
        #
        # @param text [String, nil] Description text
        # @return [String, nil]
        def description(text = nil)
          if text
            @description = text
          else
            @description
          end
        end

        # Declare a parameter for this tool.
        #
        # @param name [Symbol] Parameter name
        # @param type [String] JSON Schema type (e.g. "string", "integer")
        # @param desc [String] Parameter description
        # @return [void]
        def param(name, type: "string", desc: "")
          @params ||= []
          @params << {name: name, type: type, desc: desc}
        end

        # Return declared parameters.
        #
        # @return [Array<Hash>]
        def params
          @params || []
        end
      end

      # Derive tool name from class name.
      #
      # @return [String]
      def name
        self.class.name.split("::").last
          .gsub(/Tool$/, "")
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
      end

      # Return the class-level description.
      #
      # @return [String, nil]
      def description
        self.class.description
      end

      # Return OpenAI-format JSON schema for parameters.
      #
      # @return [Hash]
      def parameters
        props = {}
        required = []

        self.class.params.each do |p|
          props[p[:name].to_s] = {type: p[:type], description: p[:desc]}
          required << p[:name].to_s
        end

        {type: "object", properties: props, required: required}
      end

      # Invoke the tool with the given arguments.
      #
      # @param arguments [Hash] Arguments from the LLM (string keys)
      # @return [Object] Result of execute
      def call(arguments)
        args = arguments.transform_keys(&:to_sym)
        execute(**args)
      end

      # Halt the tool call loop and return content to the user.
      #
      # @param content [String] Content to return
      # @return [Tool::Halt]
      def halt(content)
        Halt.new(content)
      end

      private

      # Override in subclasses to implement tool logic.
      def execute(**args)
        raise NotImplementedError, "#{self.class}#execute must be implemented"
      end
    end
  end
end
