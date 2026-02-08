# frozen_string_literal: true

# Serves JavaScript files from the views directory.
class ScriptsAction
  # @param name [String] the name of the JavaScript file to serve
  def initialize(name)
    @name = name
  end

  # Handles the request and returns the JavaScript file content.
  #
  # @param env [Hash] the Rack environment
  # @return [Array] a Rack response tuple
  def call(env)
    js = File.read(File.join(__dir__, "..", "views", @name))
    [200, {"content-type" => "application/javascript"}, [js]]
  end
end
