# frozen_string_literal: true

# Links a cryptocurrency wallet to DeBank by fetching categorized balances
# and creating corresponding accounts for each category (wallet, protocols).
class CoinstatsItem::WalletLinker
  attr_reader :coinstats_item, :address, :blockchain

  Result = Struct.new(:success?, :created_count, :errors, keyword_init: true)

  # @param coinstats_item [CoinstatsItem] Parent item with API credentials
  # @param address [String] Wallet address to link
  # @param blockchain [String] Blockchain network identifier (kept for compatibility, not used by DeBank)
  def initialize(coinstats_item, address:, blockchain:)
    @coinstats_item = coinstats_item
    @address = address
    @blockchain = blockchain
  end

  # Fetches categorized balances and creates accounts for each category.
  # Categories include "wallet" and protocol names like "Aave", "GMX", "Aerodrome", etc.
  # @return [Result] Success status, created count, and any errors
  def link
    categorized_balances = fetch_categorized_balances

    return Result.new(success?: false, created_count: 0, errors: [ "No categories found for wallet" ]) if categorized_balances.empty?

    created_count = 0
    errors = []

    categorized_balances.each do |category_name, category_data|
      result = create_account_from_category(category_name, category_data)
      if result[:success]
        created_count += 1
      else
        errors << result[:error]
      end
    end

    # Trigger a sync if we created any accounts
    coinstats_item.sync_later if created_count > 0

    Result.new(success?: created_count > 0, created_count: created_count, errors: errors)
  end

  private

    # Fetches categorized balance data for this wallet from DeBank API.
    # @return [Hash] Categorized balances with structure: { "category_name" => { value: Float, tokens: Array } }
    def fetch_categorized_balances
      provider = Provider::Debank.new(coinstats_item.api_key)
      response = provider.get_categorized_balances(address)

      return {} unless response.success?

      response.data || {}
    end

    # Creates a CoinstatsAccount and linked Account for a category.
    # @param category_name [String] Category name (e.g., "wallet", "Aave", "GMX")
    # @param category_data [Hash] Category data with :value and :tokens
    # @return [Hash] Result with :success and optional :error
    def create_account_from_category(category_name, category_data)
      category_data = category_data.with_indifferent_access
      category_value = category_data[:value] || 0.0
      category_tokens = category_data[:tokens] || []

      account_name = build_account_name(category_name)

      ActiveRecord::Base.transaction do
        coinstats_account = coinstats_item.coinstats_accounts.create!(
          name: account_name,
          currency: "USD",
          current_balance: category_value,
          account_id: category_name # Store category name as account_id
        )

        # Store wallet metadata for future syncs
        snapshot = build_snapshot(category_name, category_value, category_tokens)
        coinstats_account.upsert_coinstats_snapshot!(snapshot)

        account = coinstats_item.family.accounts.create!(
          accountable: Crypto.new,
          name: account_name,
          balance: category_value,
          cash_balance: category_value,
          currency: coinstats_account.currency,
          status: "active"
        )

        AccountProvider.create!(account: account, provider: coinstats_account)

        { success: true }
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error("CoinstatsItem::WalletLinker - Failed to create account: #{e.message}")
      { success: false, error: "Failed to create #{account_name || 'account'}: #{e.message}" }
    rescue => e
      Rails.logger.error("CoinstatsItem::WalletLinker - Unexpected error: #{e.class} - #{e.message}")
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    # Builds a display name for the account from category name and address.
    # @param category_name [String] Category name (e.g., "wallet", "Aave")
    # @return [String] Human-readable account name
    def build_account_name(category_name)
      truncated_address = address.present? ? "#{address.first(4)}...#{address.last(4)}" : nil

      if category_name == "wallet"
        if truncated_address.present?
          "Wallet (#{truncated_address})"
        else
          "Wallet"
        end
      else
        # Protocol name
        if truncated_address.present?
          "#{category_name} (#{truncated_address})"
        else
          category_name
        end
      end
    end

    # Builds snapshot hash for storing in CoinstatsAccount.
    # @param category_name [String] Category name
    # @param category_value [Float] Total USD value for the category
    # @param category_tokens [Array<Hash>] Array of tokens in this category
    # @return [Hash] Snapshot with balance, address, and metadata
    def build_snapshot(category_name, category_value, category_tokens)
      {
        id: category_name,
        name: category_name,
        balance: category_value,
        currency: "USD",
        address: address,
        blockchain: blockchain,
        category: category_name,
        tokens: category_tokens,
        raw_balance_data: {
          value: category_value,
          tokens: category_tokens
        }
      }
    end
end
