module Accounting
  class ChartOfAccounts
    AccountTypeMismatchError = Class.new(StandardError)

    SYSTEM_ACCOUNTS = [
      { key: "cash", name: "Cash", account_type: "asset" }.freeze,
      { key: "tenant_receivable", name: "Tenant Receivable", account_type: "asset" }.freeze,
      { key: "security_deposits_held", name: "Security Deposits Held", account_type: "liability" }.freeze,
      { key: "rental_income", name: "Rental Income", account_type: "income" }.freeze,
      { key: "late_fee_income", name: "Late Fee Income", account_type: "income" }.freeze,
      { key: "reimbursement_income", name: "Reimbursement Income", account_type: "income" }.freeze,
      { key: "other_tenant_income", name: "Other Tenant Income", account_type: "income" }.freeze,
      { key: "expense_advertising", name: "Advertising", account_type: "expense" }.freeze,
      { key: "expense_cleaning_maintenance", name: "Cleaning and Maintenance", account_type: "expense" }.freeze,
      { key: "expense_insurance", name: "Insurance", account_type: "expense" }.freeze,
      { key: "expense_legal_professional", name: "Legal and Professional", account_type: "expense" }.freeze,
      { key: "expense_management", name: "Management", account_type: "expense" }.freeze,
      { key: "expense_repairs", name: "Repairs", account_type: "expense" }.freeze,
      { key: "expense_supplies", name: "Supplies", account_type: "expense" }.freeze,
      { key: "expense_taxes", name: "Taxes", account_type: "expense" }.freeze,
      { key: "expense_utilities", name: "Utilities", account_type: "expense" }.freeze,
      { key: "expense_other", name: "Other Expense", account_type: "expense" }.freeze,
      { key: "opening_balance_equity", name: "Opening Balance Equity", account_type: "equity" }.freeze
    ].freeze

    SYSTEM_KEYS = SYSTEM_ACCOUNTS.map { |defn| defn[:key] }.freeze

    def self.ensure_for(user)
      new(user).ensure_accounts
    end

    def initialize(user)
      @user = user
    end

    def ensure_accounts
      existing_accounts = user.accounts.reload.index_by(&:key)

      Account.transaction do
        SYSTEM_ACCOUNTS.each do |defn|
          key = defn[:key]
          account_type = defn[:account_type]
          name = defn[:name]

          existing = existing_accounts[key]
          if existing
            if existing.account_type != account_type
              raise AccountTypeMismatchError,
                    "Account '#{key}' for user #{user.id} has type '#{existing.account_type}', expected '#{account_type}'"
            end
          else
            created = user.accounts.create!(
              key: key,
              name: name,
              account_type: account_type,
              active: true
            )
            existing_accounts[key] = created
          end
        end
      end

      user.accounts.where(key: SYSTEM_KEYS)
    end

    private

      attr_reader :user
  end
end
