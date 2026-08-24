module ImportedTransactions
  module Parsers
    class Base
      def parse(pdf_text)
        raise NotImplementedError, "#{self.class}#parse must be implemented"
      end

      private

        def clean_name(name)
          return nil if name.blank?
          # Strip special punctuation while preserving common name characters
          name.gsub(/[^\p{Alnum}\p{Space}'\-._@]/, "").squish
        end

        def parse_amount_cents(text)
          match = text.match(/\$\s*([\d,]+\.\d{2})/)
          return nil unless match
          (BigDecimal(match[1].to_s.delete(",")) * 100).to_i
        end

        def parse_date(text)
          return nil if text.blank?

          Time.zone.parse(text)&.to_date
        rescue ArgumentError, TypeError, Date::Error
          nil
        end
    end
  end
end
