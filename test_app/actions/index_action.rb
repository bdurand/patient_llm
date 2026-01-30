# frozen_string_literal: true

class IndexAction
  def call(env)
    html = File.read(File.join(__dir__, "..", "views", "index.html"))
    [200, {"content-type" => "text/html"}, [html]]
  end
end
