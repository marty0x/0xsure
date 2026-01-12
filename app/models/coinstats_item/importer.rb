# Imports wallet data from DeBank API for linked accounts.
# Fetches categorized balances (wallet + protocols) and updates local records.
class CoinstatsItem::Importer
  include CoinstatsTransactionIdentifiable

  attr_reader :coinstats_item, :debank_provider

  # @param coinstats_item [CoinstatsItem] Item containing accounts to import
  # @param debank_provider [Provider::Debank] API client instance
  def initialize(coinstats_item, debank_provider:)
    @coinstats_item = coinstats_item
    @debank_provider = debank_provider
  end

  # Imports categorized balance data for all linked accounts.
  # Each account represents a category (wallet, protocol name, etc.)
  # @return [Hash] Result with :success, :accounts_updated, :transactions_imported
  def import
    Rails.logger.info "CoinstatsItem::Importer - Starting import for item #{coinstats_item.id}"

    # Get all linked coinstats accounts (ones with account_provider associations)
    # Each account now represents a category (wallet, protocol name, etc.)
    linked_accounts = coinstats_item.coinstats_accounts
                                    .joins(:account_provider)
                                    .includes(:account)

    if linked_accounts.empty?
      Rails.logger.info "CoinstatsItem::Importer - No linked accounts to sync for item #{coinstats_item.id}"
      return { success: true, accounts_updated: 0, transactions_imported: 0 }
    end

    accounts_updated = 0
    accounts_failed = 0

    # Extract unique wallet addresses from linked accounts
    wallet_addresses = linked_accounts.filter_map do |account|
      raw = account.raw_payload || {}
      address = raw["address"] || raw[:address]
      address if address.present?
    end.uniq

    if wallet_addresses.empty?
      Rails.logger.warn "CoinstatsItem::Importer - No wallet addresses found for item #{coinstats_item.id}"
      return { success: false, accounts_updated: 0, transactions_imported: 0, error: "No wallet addresses found" }
    end

    # Fetch categorized balances for each wallet address
    wallet_addresses.each do |wallet_address|
      begin
        response = debank_provider.get_categorized_balances(wallet_address)
        
        unless response.success?
          Rails.logger.error "CoinstatsItem::Importer - Failed to fetch balances for #{wallet_address}: #{response.error&.message}"
          accounts_failed += linked_accounts.count
          next
        end

        categorized_balances = response.data || {}

        # Update each linked account that matches a category
        linked_accounts.each do |coinstats_account|
          begin
            # Get the category name for this account (stored in account_id or name)
            category_name = coinstats_account.account_id || coinstats_account.name
            next unless category_name.present?

            category_data = categorized_balances[category_name]
            if category_data
              result = update_category_account(coinstats_account, category_data, wallet_address)
              accounts_updated += 1 if result[:success]
            else
              Rails.logger.warn "CoinstatsItem::Importer - Category '#{category_name}' not found in API response for account #{coinstats_account.id}"
            end
          rescue => e
            accounts_failed += 1
            Rails.logger.error "CoinstatsItem::Importer - Failed to update account #{coinstats_account.id}: #{e.message}"
          end
        end
      rescue => e
        Rails.logger.error "CoinstatsItem::Importer - Failed to fetch balances for wallet #{wallet_address}: #{e.message}"
        accounts_failed += linked_accounts.count
      end
    end

    Rails.logger.info "CoinstatsItem::Importer - Updated #{accounts_updated} accounts (#{accounts_failed} failed)"

    {
      success: accounts_failed == 0,
      accounts_updated: accounts_updated,
      accounts_failed: accounts_failed,
      transactions_imported: 0 # DeBank API doesn't provide transactions in the same way
    }
  end

  private

    # Updates a category account with balance data from DeBank API.
    # @param coinstats_account [CoinstatsAccount] Account representing a category
    # @param category_data [Hash] Category data with :value and :tokens
    # @param wallet_address [String] Wallet address
    # @return [Hash] Result with :success
    def update_category_account(coinstats_account, category_data, wallet_address)
      category_data = category_data.with_indifferent_access
      category_value = category_data[:value] || 0.0
      category_tokens = category_data[:tokens] || []

      # Get existing raw payload to preserve address
      existing_raw = coinstats_account.raw_payload || {}
      
      # Update the coinstats account with category balance data
      snapshot = {
        id: coinstats_account.account_id || coinstats_account.name,
        name: coinstats_account.name,
        balance: category_value,
        currency: "USD",
        address: wallet_address,
        category: coinstats_account.account_id || coinstats_account.name,
        tokens: category_tokens,
        raw_balance_data: category_data
      }

      coinstats_account.upsert_coinstats_snapshot!(snapshot)

      { success: true }
    end
end
