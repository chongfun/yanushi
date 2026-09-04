module Search
  # One search across everything a landlord names out loud: an address, a unit,
  # a tenancy, a person. Scoped to the signed-in user by construction — every
  # scope starts from the user's own association or an explicit
  # `properties.user_id` filter, so a match can never cross accounts.
  #
  # Cost: each group runs one bounded SELECT (LIMIT `limit`) plus one COUNT,
  # and the count is skipped unless the group actually filled its cap. Rows are
  # preloaded with what the templates render, so no group loops the database.
  class PortfolioQuery
    MIN_QUERY_LENGTH = 2
    GROUP_LIMIT = 5

    # One kind of result: the capped rows plus how many matched in total, so
    # the page can say "showing the first 5 of 12" and link to the index.
    Group = Data.define(:key, :records, :total_count)

    Result = Data.define(:query, :groups, :total_count)

    def self.call(user:, query:, limit: GROUP_LIMIT)
      new(user: user).call(query: query, limit: limit)
    end

    def initialize(user:)
      @user = user
    end

    def call(query:, limit: GROUP_LIMIT)
      term = query.to_s.strip
      capped_limit = [ limit.to_i, 1 ].max
      return Result.new(query: term, groups: [], total_count: 0) if term.length < MIN_QUERY_LENGTH

      pattern = like_pattern(term)
      groups = [
        group(:properties, properties_scope(pattern), order: { address: :asc }, limit: capped_limit),
        group(:rentable_units, rentable_units_scope(pattern), order: { properties: { address: :asc }, name: :asc }, limit: capped_limit),
        group(:tenancies, tenancies_scope(pattern), order: { commencement_date: :desc, id: :desc }, limit: capped_limit),
        group(:parties, parties_scope(pattern), order: { display_name: :asc }, limit: capped_limit)
      ]

      Result.new(
        query: term,
        groups: groups,
        total_count: groups.sum { |result_group| result_group.total_count }
      )
    end

    private

      attr_reader :user

      def like_pattern(term)
        "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
      end

      # Fetch at most `limit` rows, then only ask for a COUNT when the group
      # filled its cap: a group that came back short is its own total.
      def group(key, scope, order:, limit:)
        records = scope.reorder(order).limit(limit).to_a
        total_count = records.size < limit ? records.size : scope.distinct.count(:id)
        preload(key, records)

        Group.new(key: key, records: records, total_count: total_count)
      end

      def preload(key, records)
        return if records.empty?

        associations = case key
        when :rentable_units then [ :property ]
        when :tenancies then [ { rentable_unit: :property }, { tenancy_parties: :party } ]
        when :parties then [ :party_aliases ]
        else return
        end

        ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
      end

      def properties_scope(pattern)
        user.properties.where("properties.address ILIKE :q", q: pattern)
      end

      def rentable_units_scope(pattern)
        owned_units.where(
          "rentable_units.name ILIKE :q OR rentable_units.unit_identifier ILIKE :q",
          q: pattern
        )
      end

      # A tenancy is findable by anything a landlord would call it: where it is,
      # which unit, or who lives there.
      def tenancies_scope(pattern)
        owned_tenancies.left_joins(tenancy_parties: :party).where(
          "properties.address ILIKE :q OR " \
          "rentable_units.name ILIKE :q OR " \
          "rentable_units.unit_identifier ILIKE :q OR " \
          "parties.display_name ILIKE :q",
          q: pattern
        ).distinct
      end

      def parties_scope(pattern)
        user.parties.left_joins(:party_aliases).where(
          "parties.display_name ILIKE :q OR " \
          "party_aliases.alias_name ILIKE :q OR " \
          "parties.email_address ILIKE :q OR " \
          "parties.phone_number ILIKE :q",
          q: pattern
        ).distinct
      end

      def owned_units
        RentableUnit.joins(:property).where(properties: { user_id: user.id })
      end

      def owned_tenancies
        Tenancy.joins(rentable_unit: :property).where(properties: { user_id: user.id })
      end
  end
end
