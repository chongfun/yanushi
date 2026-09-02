module ImportedTransactions
  class FormDataQuery
    Result = Struct.new(
      :parties, :tenancies, :party_tenancies_map, :tenancy_parties_map,
      keyword_init: true
    )

    def initialize(user:)
      @user = user
    end

    def call
      parties = user.parties.includes(:party_aliases).order(:display_name)
      tenancies = user.tenancies.includes(rentable_unit: :property).distinct
      p_t_map = party_tenancies_map
      t_p_map = tenancy_parties_map

      Result.new(
        parties: parties,
        tenancies: tenancies,
        party_tenancies_map: p_t_map,
        tenancy_parties_map: t_p_map
      )
    end

    private

      attr_reader :user

      def party_tenancies_map
        map = Hash.new { |hash, key| hash[key] = [] }
        TenancyParty.joins(:party).where(parties: { user_id: user.id }).pluck(:party_id, :tenancy_id).each do |party_id, tenancy_id|
          map[party_id] << tenancy_id
        end
        map
      end

      def tenancy_parties_map
        map = Hash.new { |hash, key| hash[key] = [] }
        TenancyParty.joins(tenancy: { rentable_unit: :property }).where(properties: { user_id: user.id }).pluck(:tenancy_id, :party_id).each do |tenancy_id, party_id|
          map[tenancy_id] << party_id
        end
        map
      end
  end
end
