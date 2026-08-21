module ImportedTransactions
  class Error < StandardError; end
  class ParsingError < Error; end
  class ResolutionError < Error; end
  class ConfirmationError < Error; end
end
