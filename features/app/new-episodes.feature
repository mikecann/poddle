Feature: New episodes
  As a listener
  I want new episodes to land in Up Next the way each show is set up
  So the shows I care about most are always first

  Background:
    Given the listener follows "Morning Tones" with "Sunrise in A" and "Breakfast in C" in Up Next
    And they've opened Poddle signed in

  Scenario: A new episode from a normal show goes to the bottom of Up Next
    When "Morning Tones" publishes "Lunch in E"
    Then Up Next lists "Breakfast in C" then "Lunch in E"

  Scenario: A show set to "Up Next top" puts it at the top
    When they set new episodes from "Morning Tones" to "Up Next top"
    And "Morning Tones" publishes "Lunch in E"
    Then Up Next lists "Lunch in E" then "Breakfast in C"

  Scenario: A show set to "Don't add" leaves Up Next alone
    When they set new episodes from "Morning Tones" to "Don't add"
    And "Morning Tones" publishes "Lunch in E"
    Then the page for "Morning Tones" lists "Lunch in E"
    And Up Next lists "Breakfast in C"

  # "Keep latest" limits Up Next as well as downloads, like Overcast's episode limit.
  # "Sunrise in A" is first in Up Next (what's playing), so it always stays.
  Scenario: A show set to keep the latest 1 takes its older episode out of Up Next
    Given "Morning Tones" keeps the latest 1 episode
    When "Morning Tones" publishes "Lunch in E"
    Then Up Next lists "Lunch in E"
    And Up Next on the server is "Sunrise in A" and "Lunch in E"
    And "Breakfast in C" isn't played

  Scenario: Setting a show to keep the latest 1 trims Up Next straight away
    Given "Commute in D" is at the end of Up Next too
    When they set "Morning Tones" to keep the latest 1 episode
    Then Up Next lists "Commute in D"
    And "Breakfast in C" isn't played
