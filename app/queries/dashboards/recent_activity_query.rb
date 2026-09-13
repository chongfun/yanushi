module Dashboards
  class RecentActivityQuery
    def self.call(user:, through: Date.current, limit: 8)
      new(user: user, through: through, limit: limit).call
    end

    def initialize(user:, through: Date.current, limit: 8)
      @user = user
      @through = parse_through(through) || Date.current
      @limit = limit
    end

    def call
      u = user
      return [] unless u

      entries = u.journal_entries
                 .where("occurred_on <= ?", through)
                 .order(occurred_on: :desc, id: :desc)
                 .limit(limit)
                 .includes(
                   :source,
                   :reversal,
                   postings: [ :account, :property, :rentable_unit, :tenancy, :party ],
                   reversal_of: [
                     :source,
                     :reversal,
                     postings: [ :account, :property, :rentable_unit, :tenancy, :party ]
                   ]
                 )

      entries.map do |entry|
        Accounting::ActivityProjector.project(entry, as_of: through)
      end
    end

    private

      attr_reader :user, :through, :limit

      def parse_through(val)
        return nil if val.blank?
        return val if val.is_a?(Date)
        return val.to_date if val.respond_to?(:to_date)

        Date.parse(val.to_s.strip)
      rescue ArgumentError, Date::Error
        nil
      end
  end
end
