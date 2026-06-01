# app/services/payment_ingestions/tenant_resolver.rb
require "dry/monads"
require "dry/struct"

module PaymentIngestions
  class TenantResolver
    class ResolveResult < Dry::Struct
      extend Dry::Monads[:result]

      attribute? :tenant, ServiceResultTypes::Any.optional
      attribute? :tenants, ServiceResultTypes::Array.of(ServiceResultTypes::Any).optional
      attribute :status, ServiceResultTypes::Symbol

      def self.matched(tenant:, tenants:)
        Success(new(tenant: tenant, tenants: tenants, status: :matched))
      end

      def self.ambiguous(tenants:)
        Failure(new(tenant: nil, tenants: tenants, status: :ambiguous))
      end

      def self.unmatched
        Failure(new(tenant: nil, tenants: [], status: :unmatched))
      end
    end

    def resolve(user, display_name, username)
      return ResolveResult.unmatched if display_name.blank? && username.blank?

      candidates = find_candidates(user, display_name, username)

      case candidates.size
      when 0
        ResolveResult.unmatched
      when 1
        ResolveResult.matched(tenant: candidates.first, tenants: candidates)
      else
        ResolveResult.ambiguous(tenants: candidates)
      end
    end

    private

    def find_candidates(user, display_name, username)
      # @type var search_values: Array[String]
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
