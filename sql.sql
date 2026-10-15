-- Add Job
INSERT INTO `jobs` (`name`, `label`) VALUES
('companyjob', 'The Gold Leaf');

INSERT INTO `job_grades` (`job_name`, `grade`, `name`, `label`, `salary`, `skin_male`, `skin_female`) VALUES
('companyjob', 0, 'recruit', 'Recruit', 200, '{}', '{}'),
('companyjob', 1, 'transporter', 'Transporter', 400, '{}', '{}'),
('companyjob', 2, 'underboss', 'Underboss', 600, '{}', '{}'),
('companyjob', 3, 'boss', 'Boss', 800, '{}', '{}');

INSERT INTO `addon_account` (`name`, `label`, `shared`) VALUES
('society_companyjob', 'Company Job', 1);

INSERT INTO `addon_inventory` (`name`, `label`, `shared`) VALUES
('society_companyjob', 'TCompany Job', 1),
('society_companyjob_depot', 'Company Depot', 1);

INSERT INTO `datastore` (`name`, `label`, `shared`) VALUES
('society_companyjob', 'Company Job', 1);

CREATE TABLE IF NOT EXISTS `convoy_list` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `convoy_list` (`id`) VALUES 
(1), (2), (3), (4), (5);

CREATE TABLE IF NOT EXISTS `convoy_registered_list` (
    `identifier` varchar(50) NOT NULL,
    `is_trailer_stored` tinyint(1) DEFAULT 0,
    `convoy_id` int(11) DEFAULT 0,
    `is_paid` tinyint(1) DEFAULT 0,
    PRIMARY KEY (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;