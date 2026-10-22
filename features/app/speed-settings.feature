Feature: Speed settings
  As a listener
  I want one default speed, and my own speed for the odd show
  So most shows just follow my default

  Background:
    Given the listener follows "Morning Tones" with "Sunrise in A" in Up Next
    And they also follow "Evening Echoes" with "Dusk" at the end of Up Next
    And they've opened Poddle signed in
    And they've opened the playback settings in Now Playing

  Scenario: With "Customize" off, changing the speed changes the default for every show
    When they choose 1.4× speed
    Then the default speed is 1.4×
    And "Morning Tones" has no speed of its own
    When they play "Dusk"
    Then Now Playing's speed is 1.4×

  Scenario: Turning "Customize" on gives the show its own speed, and off returns it to the default
    When they turn on "Customize for Morning Tones"
    And they choose 1.8× speed
    Then "Morning Tones" has its own speed of 1.8×
    And the default speed is 1×
    When they play "Dusk"
    Then Now Playing's speed is 1×
    When they play "Sunrise in A"
    Then Now Playing's speed is 1.8×
    When they open the playback settings
    And they turn off "Customize for Morning Tones"
    Then "Morning Tones" has no speed of its own
    And Now Playing's speed is 1×
