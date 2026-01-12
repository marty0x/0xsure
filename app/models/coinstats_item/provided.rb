module CoinstatsItem::Provided
  extend ActiveSupport::Concern

  def debank_provider
    return nil unless credentials_configured?

    Provider::Debank.new(api_key)
  end

  # Alias for backward compatibility during transition
  alias_method :coinstats_provider, :debank_provider
end
