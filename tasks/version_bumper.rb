# frozen_string_literal: true

# Pure semantic-version arithmetic for the `bump:*` Rake tasks. Kept out of
# lib/ so it is never packaged into the gem (spec.files globs lib/**/*.rb only).
module VersionBumper
  LEVELS = %i[major minor patch].freeze

  def self.next(current, level)
    level = level.to_sym
    validate_level!(level)
    parts = parse_version!(current)
    compute_next(parts, level)
  end

  def self.validate_level!(level)
    return if LEVELS.include?(level)

    raise ArgumentError, "unknown level #{level.inspect}, expected one of #{LEVELS.inspect}"
  end
  private_class_method :validate_level!

  def self.parse_version!(current)
    parts = current.split('.')
    valid = parts.length == 3 && parts.all? { |p| p.match?(/\A\d+\z/) }
    raise ArgumentError, "malformed version #{current.inspect}, expected MAJOR.MINOR.PATCH" unless valid

    parts.map(&:to_i)
  end
  private_class_method :parse_version!

  def self.compute_next(parts, level)
    major, minor, patch = parts
    case level
    when :major then "#{major + 1}.0.0"
    when :minor then "#{major}.#{minor + 1}.0"
    when :patch then "#{major}.#{minor}.#{patch + 1}"
    end
  end
  private_class_method :compute_next
end
