# frozen_string_literal: true

class StylesAction
  def call(env)
    css = File.read(File.join(__dir__, "..", "views", "styles.css"))
    [200, {"content-type" => "text/css"}, [css]]
  end
end
