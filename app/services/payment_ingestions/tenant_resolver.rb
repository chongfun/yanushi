require "dry/monads"
require "dry/struct"

module PaymentIngestions
  class TenantResolver
    class ResolveResult < Dry::Struct
      extend Dry::Monads[:result]

      attribute? :party, ServiceResultTypes::Any.optional
      attribute? :parties, ServiceResultTypes::Array.of(ServiceResultTypes::Any).optional
      attribute :status, ServiceResultTypes::Symbol

      def self.matched(party:, parties: [ party ])
        Success(new(party: party, parties: parties, status: :matched))
      end

      def self.ambiguous(parties: [])
        Failure(new(party: nil, parties: parties, status: :ambiguous))
      end

      def self.unmatched
        Failure(new(party: nil, parties: [], status: :unmatched))
      end
    end

    def resolve(user, display_name, username)
      return ResolveResult.unmatched if display_name.blank? && username.blank?

      candidates = find_candidates(user, display_name, username)

      case candidates.size
      when 0
        ResolveResult.unmatched
      when 1
        ResolveResult.matched(party: candidates.first, parties: candidates)
      else
        ResolveResult.ambiguous(parties: candidates)
      end
    end

    private

      def find_candidates(user, display_name, username)
        search_values = [] # : Array[String]
        search_values << username.strip.downcase if username.present?
        search_values << display_name.strip.downcase if display_name.present?

        return [] if search_values.empty?

        user.parties
            .left_outer_joins(:party_aliases)
            .where(
              "LOWER(parties.display_name) IN (?) OR LOWER(party_aliases.alias_name) IN (?)",
              search_values,
              search_values
            )
            .distinct
            .to_a
      end
  end
end
