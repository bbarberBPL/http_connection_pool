# frozen_string_literal: true

require_relative '../tasks/version_bumper'

RSpec.describe VersionBumper do
  describe '.next' do
    it 'bumps the patch component' do
      expect(described_class.next('0.1.0', :patch)).to eq('0.1.1')
    end

    it 'bumps the minor component and zeroes patch' do
      expect(described_class.next('0.1.4', :minor)).to eq('0.2.0')
    end

    it 'bumps the major component and zeroes minor and patch' do
      expect(described_class.next('1.4.9', :major)).to eq('2.0.0')
    end

    it 'accepts the level as a string' do
      expect(described_class.next('0.1.0', 'minor')).to eq('0.2.0')
    end

    it 'raises on an unknown level' do
      expect { described_class.next('0.1.0', :bogus) }.to raise_error(ArgumentError, /level/)
    end

    it 'raises on a malformed version' do
      expect { described_class.next('0.1', :patch) }.to raise_error(ArgumentError, /version/)
    end
  end
end
