-- FAKE business rows for ./kit test ONLY (loaded into the throwaway test database, never a real one).
-- Every value is made up: UIDs start with FAKE-, IMEIs are all-zero test numbers, contacts say (fake).
-- Shape needed by the business tests: >= 13 items (one test opens item #13), >= 3 with "iPhone" in
-- the name (search ranking), several Sold, a few categories, some leads and exit profiles.
-- Item names were checked against the tests' stub embedder (hashed words): e.g. "S21" lands in the
-- same hash bucket as "iphone", so an item called "Galaxy S21" would out-rank real iPhones there.
BEGIN;
INSERT INTO public."Business" ("UID","Item","Category","Condition","Acquisition_Date","Buy_Price","Parts_Invested","Platform","IMEI","Battery__","Status","Listed_On","List_Price","Sold_Date","Sold_Price","Notes",created_at,updated_at) VALUES
('FAKE-001','iPhone 12 128GB Blue','Phone','Good','2026-03-02',120,15,'Marketplace','000000000000001',88,'Sold','eBay',220,'2026-04-03',210,'fake row','2026-03-02 10:00','2026-04-03 10:00'),
('FAKE-002','iPhone 13 Pro 256GB','Phone','Fair','2026-03-05',260,40,'OfferUp','000000000000002',84,'Sold','Swappa',420,'2026-04-18',405,'fake row','2026-03-05 10:00','2026-04-18 10:00'),
('FAKE-003','iPhone 11 64GB cracked back','Phone','Cracked','2026-03-10',60,35,'Marketplace','000000000000003',79,'Listed','eBay',150,null,null,'fake row','2026-03-10 10:00','2026-04-20 10:00'),
('FAKE-004','iPhone SE 2020 64GB','Phone','Good','2026-04-01',45,null,'Craigslist','000000000000004',91,'Active',null,null,null,null,'fake row','2026-04-01 10:00','2026-04-21 10:00'),
('FAKE-005','Android phone 128GB','Phone','Good','2026-02-11',110,null,'Marketplace','000000000000005',86,'Sold','eBay',200,'2026-03-20',190,'fake row','2026-02-11 10:00','2026-03-20 10:00'),
('FAKE-006','Pixel 6 128GB','Phone','Fair','2026-02-15',80,20,'Marketplace',null,null,'Non-Liquid',null,null,null,null,'fake row','2026-02-15 10:00','2026-04-22 10:00'),
('FAKE-007','Gaming console slim 1TB','Gaming','Good','2026-02-20',150,null,'Craigslist',null,null,'Sold','Marketplace',260,'2026-03-28',250,'fake row','2026-02-20 10:00','2026-03-28 10:00'),
('FAKE-008','Handheld gaming console','Gaming','Fair','2026-01-08',95,10,'Marketplace',null,null,'Listed','eBay',170,null,null,'fake row','2026-01-08 10:00','2026-04-23 10:00'),
('FAKE-009','Trading card lot (50 cards)','Cards','Near Mint','2026-01-09',25,null,'Local',null,null,'Active',null,null,null,null,'fake row','2026-01-09 10:00','2026-04-24 10:00'),
('FAKE-010','Sealed booster box','Cards','Sealed','2026-01-12',95,null,'Local',null,null,'Listed','eBay',160,null,null,'fake row','2026-01-12 10:00','2026-04-25 10:00'),
('FAKE-011','Tablet 10in 64GB','Tablet','Good','2026-03-14',70,10,'Marketplace',null,null,'Sold','Marketplace',140,'2026-04-25',135,'fake row','2026-03-14 10:00','2026-04-26 10:00'),
('FAKE-012','Laptop 13in 8GB','Laptop','Fair','2026-03-22',110,60,'Craigslist',null,null,'Active',null,null,null,null,'fake row','2026-03-22 10:00','2026-04-27 10:00'),
('FAKE-013','Smartwatch 44mm','Watch','Good','2026-03-25',55,null,'OfferUp',null,null,'Sold','eBay',120,'2026-04-28',115,'fake row','2026-03-25 10:00','2026-04-28 10:00'),
('FAKE-014','Wireless earbuds','Audio','Good','2026-03-27',30,null,'Marketplace',null,null,'Listed','eBay',70,null,null,'fake row','2026-03-27 10:00','2026-04-29 10:00'),
('FAKE-015','iPhone 14 128GB parts only','Phone','For parts','2026-03-29',90,null,'Marketplace','000000000000015',null,'Non-Liquid',null,null,null,null,'fake row','2026-03-29 10:00','2026-04-30 10:00');
INSERT INTO public."Leads" ("Lead","Contact","Device","Their_Ask","My_Offer","Est__Grade","Status","Next_Touch","Source","Notes","Business_id",created_at,updated_at) VALUES
('Fake lead 1','fake-contact-1 (fake)','iPhone 12 mini',150,110,'B','Open','2026-11-02','Marketplace','fake row',null,'2026-04-01 10:00','2026-04-01 10:00'),
('Fake lead 2','fake-contact-2 (fake)','Gaming console',200,140,'C','Passed',null,'OfferUp','fake row',null,'2026-04-02 10:00','2026-04-02 10:00'),
('Fake lead 3','fake-contact-3 (fake)','Tablet 10in',90,60,'B','Bought','2026-04-10','Craigslist','fake row',11,'2026-04-03 10:00','2026-04-03 10:00');
INSERT INTO public."Exit Profiles" ("Exit_Name","Exit_Type","Buyer___Contact","Grade_Floor","Accepts_Bad_ESN","Accepts_No_Power","Price_Basis","Fees___Costs","Turnaround","Active","Notes",created_at,updated_at) VALUES
('Fake buyback shop','Buyback','fake-buyer (fake)','C','No','No','Quote','None','Same day',true,'fake row','2026-04-01 10:00','2026-04-01 10:00'),
('Fake parts buyer','Parts','fake-parts (fake)','D','Yes','Yes','Per lot','Shipping','1 week',false,'fake row','2026-04-02 10:00','2026-04-02 10:00');
COMMIT;
