# app/services/payment_ingestions/parsers/zelle.rb
module PaymentIngestions
  module Parsers
    class Zelle < Base
      def parse(pdf_text)
        raw_payer = extract_payer(pdf_text)
        IngestionResult.new(
          receipt_type: "zelle",
          payment_method: "zelle",
          raw_text: pdf_text,
          payer_name: clean_name(raw_payer),
          payer_username: nil,
          amount: extract_amount(pdf_text),
          payment_date: extract_date(pdf_text),
          transaction_number: extract_transaction_id(pdf_text),
          success: true
        )
      rescue => e
        Rails.logger.error("Zelle parser error: #{e.message}\n#{e.backtrace.join("\n")}")
        IngestionResult.new(
          receipt_type: "zelle",
          raw_text: pdf_text,
          error_message: e.message,
          success: false
        )
      end

      private

      def extract_payer(text)
        # Match from "Sender" column layout:
        # Completed                         JANE DOE
        # Or match from header / sentence: "JANE DOE sent you money"
        match = text.match(/Completed\s+([A-Za-z ]+?)\s+(?:In moments|Scheduled)/i)
        return match[1].strip if match

        match = text.match(/(.+?)\s+sent you money/i)
        match&.[](1)&.strip
      end

      def extract_amount(text)
        parse_amount(text)
      end

      def extract_date(text)
        # Look for the date, e.g., "Dec 4, 2023" or "Mar 24, 2026"
        match = text.match(/([a-zA-Z]{3}\s+\d{1,2},\s+\d{4})/i)
        return nil unless match
        parse_date(match[1].strip)
      end

      def extract_transaction_id(text)
        match = text.match(/Transaction number\s+(\S+)/i)
        match&.[](1)
      end
    end
  end
end
