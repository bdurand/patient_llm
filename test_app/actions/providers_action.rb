# frozen_string_literal: true

require "json"

class ProvidersAction
  def call(_env)
    providers = PremiumProviders.available.map do |name, config|
      {name: name, label: config[:label], default_model: config[:default_model]}
    end

    [200, {"content-type" => "application/json"}, [providers.to_json]]
  end
end
