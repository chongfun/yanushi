module ImportedTransactions
  module Parsers
    class Venmo < Base
      def parse(pdf_text)
        raw_payer = extract_payer(pdf_text)
        raw_username = extract_username(pdf_text)
        IngestionResult.success(
          document_type: "venmo",
          payment_method: "venmo",
          raw_text: pdf_text,
          payer_name: clean_name(raw_payer),
          payer_username: clean_name(raw_username),
          amount_cents: extract_amount_cents(pdf_text),
          occurred_on: extract_date(pdf_text),
          external_reference: extract_transaction_id(pdf_text)
        )
      rescue => e
        Rails.logger.error("Venmo parser error: #{e.message}\n#{e.backtrace.join("\n")}")
        IngestionResult.failure(
          document_type: "venmo",
          raw_text: pdf_text,
          error_message: e.message
        )
      end

      private

        def extract_payer(text)
          lines = text.split("\n").map(&:strip).reject(&:empty?)
          idx = lines.index("Transaction details")
          if idx && lines[idx + 1]
            lines[idx + 1]
          end
        end

        def extract_username(text)
          match = text.match(/Received from\s+(@\S+)/i)
          match&.[](1)
        end

        def extract_amount_cents(text)
          parse_amount_cents(text)
        end

        def extract_date(text)
          match = text.match(/([a-zA-Z]{3}\s+\d{1,2},\s+\d{4},\s+\d{1,2}:\d{2}\s+(?:AM|PM))/i)
          return parse_date(match[1].to_s.strip) if match

          match = text.match(/([a-zA-Z]{3}\s+\d{1,2},\s+\d{4})/i)
          return parse_date(match[1].to_s.strip) if match

          nil
        end

        def extract_transaction_id(text)
          match = text.match(/Transaction ID\s+(\d+)/i)
          match&.[](1)
        end
    end
  end
end
