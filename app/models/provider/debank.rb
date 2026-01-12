# API client for DeBank cryptocurrency data provider.
# Handles authentication and requests to the DeBank OpenAPI.
require "set"

class Provider::Debank < Provider
  include HTTParty

  # Subclass so errors caught in this provider are raised as Provider::Debank::Error
  Error = Class.new(Provider::Error)

  BASE_URL = "https://api.connect.debank.com"

  headers "User-Agent" => "Sure Finance DeBank Client (https://github.com/we-promise/sure)"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  attr_reader :api_key

  # @param api_key [String] DeBank API key for authentication
  def initialize(api_key)
    @api_key = api_key
  end

  # Get all token balances for a wallet address across all chains
  # https://docs.cloud.debank.com/en/readme/api-pro-reference/user
  # @param wallet_address [String] Wallet address to fetch balances for
  # @return [Provider::Response] Response with token balance data
  def get_wallet_tokens(wallet_address)
    return with_provider_response { [] } if wallet_address.blank?

    with_provider_response do
      res = self.class.get(
        "#{BASE_URL}/v1/user/all_token_list",
        headers: auth_headers,
        query: { id: wallet_address }
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "DeBank API: GET /v1/user/all_token_list failed: #{e.class}: #{e.message}"
    raise Error, "DeBank API request failed: #{e.message}"
  end

  # Get all protocol positions for a wallet address
  # This includes tokens held in DeFi protocols like Aave, GMX, Aerodrome, etc.
  # https://docs.cloud.debank.com/en/readme/api-pro-reference/user
  # @param wallet_address [String] Wallet address to fetch protocol positions for
  # @return [Provider::Response] Response with protocol position data
  def get_wallet_protocols(wallet_address)
    return with_provider_response { [] } if wallet_address.blank?

    with_provider_response do
      res = self.class.get(
        "#{BASE_URL}/v1/user/all_complex_protocol_list",
        headers: auth_headers,
        query: { id: wallet_address }
      )
      handle_response(res)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "DeBank API: GET /v1/user/all_complex_protocol_list failed: #{e.class}: #{e.message}"
    raise Error, "DeBank API request failed: #{e.message}"
  end

  # Get categorized balances for a wallet address
  # Groups tokens into categories: "wallet" for native holdings and protocol names for DeFi positions
  # @param wallet_address [String] Wallet address to fetch categorized balances for
  # @return [Provider::Response] Response with categorized balance data
  #   Format: { "wallet" => { value: 1000.0, tokens: [...] }, "Aave" => { value: 500.0, tokens: [...] }, ... }
  def get_categorized_balances(wallet_address)
    return with_provider_response { {} } if wallet_address.blank?

    with_provider_response do
      # Fetch both tokens and protocols in parallel would be ideal, but for simplicity we'll do sequentially
      tokens_response = get_wallet_tokens(wallet_address)
      protocols_response = get_wallet_protocols(wallet_address)

      tokens = tokens_response.success? ? (tokens_response.data || []) : []
      protocols = protocols_response.success? ? (protocols_response.data || []) : []

      categorize_balances(tokens, protocols)
    end
  end

  private

    def auth_headers
      {
        "Authorization" => "Bearer #{api_key}",
        "Accept" => "application/json"
      }
    end

    # Categorizes tokens into wallet and protocol categories
    # @param tokens [Array<Hash>] Array of token data from all_token_list
    # @param protocols [Array<Hash>] Array of protocol data from all_complex_protocol_list
    # @return [Hash] Categorized balances with structure: { "category_name" => { value: Float, tokens: Array } }
    def categorize_balances(tokens, protocols)
      categories = {}
      protocol_token_ids = Set.new

      # Process protocols first to identify which tokens belong to protocols
      protocols.each do |protocol|
        protocol_data = protocol.with_indifferent_access
        protocol_name = protocol_data[:name] || protocol_data[:protocol_name] || "Unknown Protocol"
        
        # Initialize category if not exists
        categories[protocol_name] = { value: 0.0, tokens: [] }

        # Extract tokens from protocol positions
        # Protocol structure can vary, but typically has portfolio_item_list or similar
        portfolio_items = protocol_data[:portfolio_item_list] || protocol_data[:portfolio_items] || []
        
        portfolio_items.each do |item|
          item = item.with_indifferent_access
          # Look for asset_token_list or similar structure
          asset_tokens = item[:asset_token_list] || item[:tokens] || item[:assets] || []
          
          asset_tokens.each do |asset|
            asset = asset.with_indifferent_access
            token_id = asset[:id] || asset[:token_id] || asset[:chain] + ":" + (asset[:address] || "")
            protocol_token_ids.add(token_id)
            
            # Calculate USD value
            amount = asset[:amount] || asset[:balance] || 0
            price = asset[:price] || asset[:price_usd] || 0
            usd_value = amount.to_f * price.to_f
            
            categories[protocol_name][:value] += usd_value
            categories[protocol_name][:tokens] << asset
          end
        end
      end

      # Process wallet tokens (tokens not in any protocol)
      wallet_value = 0.0
      wallet_tokens = []

      tokens.each do |token|
        token = token.with_indifferent_access
        token_id = token[:id] || token[:token_id] || (token[:chain] || "") + ":" + (token[:address] || "")
        
        # Skip if token is already accounted for in a protocol
        next if protocol_token_ids.include?(token_id)

        # Calculate USD value
        amount = token[:amount] || token[:balance] || 0
        price = token[:price] || token[:price_usd] || 0
        usd_value = amount.to_f * price.to_f
        
        wallet_value += usd_value
        wallet_tokens << token
      end

      # Add wallet category if there are any wallet tokens
      if wallet_value > 0 || wallet_tokens.any?
        categories["wallet"] = { value: wallet_value, tokens: wallet_tokens }
      end

      categories
    end

    # The DeBank API uses standard HTTP status codes to indicate the success or failure of requests.
    def handle_response(response)
      case response.code
      when 200
        JSON.parse(response.body, symbolize_names: true)
      when 400
        log_api_error(response, "Bad Request")
        raise Error, "DeBank: Invalid request parameters"
      when 401
        log_api_error(response, "Unauthorized")
        raise Error, "DeBank: Invalid or missing API key"
      when 403
        log_api_error(response, "Forbidden")
        raise Error, "DeBank: Access denied"
      when 404
        log_api_error(response, "Not Found")
        raise Error, "DeBank: Resource not found"
      when 429
        log_api_error(response, "Too Many Requests")
        raise Error, "DeBank: Rate limit exceeded, try again later"
      when 500
        log_api_error(response, "Internal Server Error")
        raise Error, "DeBank: Server error, try again later"
      when 503
        log_api_error(response, "Service Unavailable")
        raise Error, "DeBank: Service temporarily unavailable"
      else
        log_api_error(response, "Unexpected Error")
        raise Error, "DeBank: An unexpected error occurred"
      end
    end

    def log_api_error(response, error_type)
      Rails.logger.error "DeBank API: #{response.code} #{error_type} - #{response.body}"
    end
end
