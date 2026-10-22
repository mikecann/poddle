Feature: Now Playing
  As a listener
  I want Now Playing's three pages and an artwork I can't fumble
  So I can read the notes, tweak playback, and never lose an episode by accident

  Background:
    Given the listener follows "Chapter Chimes" with "Three Movements" in Up Next
    And they've opened Poddle signed in
    And they've opened Now Playing

  Scenario: Swipe right for the show notes, where a timestamp seeks
    When they swipe right on Now Playing
    Then Now Playing shows the show notes with chapters "Overture", "The middle bit" and "Finale"
    When they tap the timestamp "0:40" in the show notes
    And they go back to the player page
    Then the position is about 40 seconds

  Scenario: Swipe left for the playback settings
    When they swipe left on Now Playing
    Then Now Playing shows the playback settings for "Chapter Chimes"

  Scenario: Dragging the artwork never archives or skips
    When they drag the artwork left, right and up
    Then "Three Movements" is still what's playing
    And "Three Movements" isn't archived
    And "Three Movements" isn't played
    And Up Next on the server is "Three Movements"
