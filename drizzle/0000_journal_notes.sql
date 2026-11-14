CREATE TABLE `journal_notes` (
  `account` text NOT NULL,
  `id` text NOT NULL,
  `revision` integer NOT NULL,
  `payload` text,
  PRIMARY KEY (`account`, `id`)
);
