class ShardedRecord < ActiveRecord::Base
  self.abstract_class = true

  establish_connection :shard_one

  connects_to shards: {
    default: { writing: :shard_one },
    shard_two: { writing: :shard_two }
  }
end
