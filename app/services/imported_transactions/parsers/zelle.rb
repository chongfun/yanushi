module ImportedTransactions
  module Parsers
    class Zelle < Base
      def parse(pdf_text)
        raw_payer = extract_payer(pdf_text)
        IngestionResult.success(
          document_type: "zelle",
          payment_method: "zelle",
          raw_text: pdf_text,
          payer_name: clean_name(raw_payer),
          payer_username: nil,
          amount_cents: extract_amount_cents(pdf_text),
          occurred_on: extract_date(pdf_text),
          external_reference: extract_transaction_id(pdf_text)
        )
      rescue => e
        Rails.logger.error("Zelle parser error: #{e.message}\n#{e.backtrace.join("\n")}")
        IngestionResult.failure(
          document_type: "zelle",
          raw_text: pdf_text,
          error_message: e.message
        )
      end

      private

        def extract_payer(text)
          match = text.match(/Completed\s+([\p{L}\s'\-]+?)\s+(?:In moments|Scheduled)/i)
          return match[1].to_s.strip if match

          match = text.match(/(.+?)\s+sent you money/i)
          match&.[](1)&.strip
        end

        def extract_amount_cents(text)
          parse_amount_cents(text)
        end

        def extract_date(text)
          match = text.match(/([a-zA-Z]{3}\s+\d{1,2},\s+\d{4})/i)
          return nil unless match

          parse_date(match[1].to_s.strip)
        end

        def extract_transaction_id(text)
          match = text.match(/Transaction number\s+(\S+)/i)
          match&.[](1)
        end
    end
  end
end
