module Accounting
  class AccountBalanceQuery
    def self.call(account:, as_of: nil, property: nil, rentable_unit: nil, tenancy: nil, party: nil, user: nil)
      new(
        account: account,
        as_of: as_of,
        property: property,
        rentable_unit: rentable_unit,
        tenancy: tenancy,
        party: party,
        user: user
      ).natural_balance_cents
    end

    def initialize(account:, as_of: nil, property: nil, rentable_unit: nil, tenancy: nil, party: nil, user: nil)
      @account = account
      @as_of = parse_as_of(as_of)
      @property = property
      @rentable_unit = rentable_unit
      @tenancy = tenancy
      @party = party
      @user = user || account&.user
    end

    def raw_balance_cents
      return 0 unless account

      scope = account.postings.joins(:journal_entry)
      scope = scope.where("journal_entries.occurred_on <= ?", as_of) if as_of.present?
      scope = scope.where(property_id: property.id) if property
      scope = scope.where(rentable_unit_id: rentable_unit.id) if rentable_unit
      scope = scope.where(tenancy_id: tenancy.id) if tenancy
      scope = scope.where(party_id: party.id) if party

      scope.sum(:amount_cents)
    end

    def natural_balance_cents
      return 0 unless account

      NaturalBalance.convert(account, raw_balance_cents)
    end

    def raw_balance
      BigDecimal(raw_balance_cents.to_s) / 100
    end

    def natural_balance
      BigDecimal(natural_balance_cents.to_s) / 100
    end

    alias_method :balance_cents, :natural_balance_cents
    alias_method :balance, :natural_balance

    private

      attr_reader :account, :as_of, :property, :rentable_unit, :tenancy, :party, :user

      def parse_as_of(val)
        return nil if val.blank?
        return val if val.is_a?(Date)
        return val.to_date if val.respond_to?(:to_date)

        Date.parse(val.to_s.strip)
      rescue ArgumentError, Date::Error
        nil
      end
  end
end
