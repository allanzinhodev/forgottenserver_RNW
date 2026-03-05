function onUpdateDatabase()
	print("> Updating database to version 33 (FFTA spell learning: player_equipment_ab_kills)")

	db.query([[
		CREATE TABLE IF NOT EXISTS `player_equipment_ab_kills` (
			`player_id` int NOT NULL,
			`item_id`   int unsigned NOT NULL,
			`creature`  varchar(100) NOT NULL DEFAULT '',
			`kills`     int unsigned NOT NULL DEFAULT 0,
			PRIMARY KEY (`player_id`, `item_id`, `creature`),
			FOREIGN KEY (`player_id`) REFERENCES `players`(`id`) ON DELETE CASCADE
		) ENGINE=InnoDB DEFAULT CHARACTER SET=utf8;
	]])

	return true
end
