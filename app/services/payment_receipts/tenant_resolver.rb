# app/services/payment_receipts/tenant_resolver.rb
module PaymentReceipts
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
      results = []

      # Try matching by username if present (e.g. "@handle")
      if username.present?
        normalized_username = username.strip.downcase
        results += user.tenants.where("LOWER(name) = ?", normalized_username).to_a
        results += user.tenants.joins(:tenant_aliases).where("LOWER(tenant_aliases.alias_name) = ?", normalized_username).to_a
      end

      # Try matching by display name
      if display_name.present?
        normalized_name = display_name.strip.downcase
        results += user.tenants.where("LOWER(name) = ?", normalized_name).to_a
        results += user.tenants.joins(:tenant_aliases).where("LOWER(tenant_aliases.alias_name) = ?", normalized_name).to_a
      end

      results.uniq
    end
  end
end
