Feature: Share links
  As someone who's been sent a Poddle link
  I want it to open the episode in the app
  So I can play it from the moment they meant

  Scenario: A link with a start time offers to play from there
    Given someone else follows "Chapter Chimes"
    And the listener has an account
    When the listener opens the share link for "Three Movements" at 40 seconds
    Then the episode page for "Three Movements" opens
    And it offers "Play from 0:40"
    And its show notes list "0:20 The middle bit" and "0:40 The finale" on their own lines
    When they play from there
    Then Now Playing shows "Three Movements"
    And the position is about 40 seconds

  Scenario: A dead link says it couldn't be opened
    Given the listener has an account
    When the listener opens a share link to an episode that doesn't exist
    Then they're told the link couldn't be opened
