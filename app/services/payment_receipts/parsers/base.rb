# app/services/payment_receipts/parsers/base.rb
module PaymentReceipts
  module Parsers
    class Base
      def parse(pdf_text)
        raise NotImplementedError, "#{self.class}#parse must be implemented"
      end

      private

      def clean_name(name)
        return nil if name.blank?
        # Keep letters, numbers, spaces, apostrophes, hyphens, periods, underscores, and @
        name.gsub(/[^\p{Alnum}\p{Space}'\-._@]/, "").squish
      end

      def parse_amount(text)
        match = text.match(/\$\s*([\d,]+\.\d{2})/)
        return nil unless match
        BigDecimal(match[1].delete(","))
      end

      def parse_date(text)
        # Parse within the active Time.zone context
        Time.zone.parse(text)&.to_date
      rescue ArgumentError, Date::Error
        nil
      end
    end
  end
end
