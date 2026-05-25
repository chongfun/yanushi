# app/services/payment_ingestions/tenant_resolver.rb
module PaymentIngestions
  class TenantResolver
    ResolveResult = Struct.new(:tenant, :tenants, :status, keyword_init: true)

    def resolve(user, display_name, username)
      return ResolveResult.new(status: :unmatched) if display_name.blank? && username.blank?

      candidates = find_candidates(user, display_name, username)

      case candidates.size
      when 0
        ResolveResult.new(status: :unmatched)
      when 1
        ResolveResult.new(tenant: candidates.first, tenants: candidates, status: :matched)
      else
        ResolveResult.new(tenants: candidates, status: :ambiguous)
      end
    end

    private

    def find_candidates(user, display_name, username)
      search_values = []
      search_values << username.strip.downcase if username.present?
      search_values << display_name.strip.downcase if display_name.present?

      return [] if search_values.empty?

      user.tenants
          .left_outer_joins(:tenant_aliases)
          .where(
            "LOWER(tenants.name) IN (?) OR LOWER(tenant_aliases.alias_name) IN (?)",
            search_values,
            search_values
          )
          .distinct
          .to_a
    end
  end
end
