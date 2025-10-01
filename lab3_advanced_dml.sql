CREATE TABLE employees (
                           emp_id SERIAL PRIMARY KEY,
                           first_name VARCHAR(50) NOT NULL,
                           last_name VARCHAR(50) NOT NULL,
                           department VARCHAR(50),
                           salary INTEGER,
                           hire_date DATE,
                           status VARCHAR(20) DEFAULT 'Active'
);

CREATE TABLE departments (
                             dept_id SERIAL PRIMARY KEY,
                             dept_name VARCHAR(50) NOT NULL,
                             budget INTEGER,
                             manager_id INTEGER
);

CREATE TABLE projects (
                          project_id SERIAL PRIMARY KEY,
                          project_name VARCHAR(100) NOT NULL,
                          dept_id INTEGER,
                          start_date DATE,
                          end_date DATE,
                          budget INTEGER
);

INSERT INTO departments (dept_name, budget, manager_id) VALUES
                                                            ('IT', 150000, 1),
                                                            ('Sales', 120000, 2),
                                                            ('HR', 80000, 3),
                                                            ('Finance', 200000, 4);

INSERT INTO employees (first_name, last_name, department, salary, hire_date, status) VALUES
                                                                                         ('John', 'Doe', 'IT', 60000, '2019-05-15', 'Active'),
                                                                                         ('Jane', 'Smith', 'Sales', 55000, '2020-02-20', 'Active'),
                                                                                         ('Mike', 'Johnson', 'IT', 75000, '2018-08-10', 'Active'),
                                                                                         ('Sarah', 'Wilson', 'HR', 45000, '2021-01-30', 'Inactive'),
                                                                                         ('Tom', 'Brown', 'Finance', 90000, '2017-11-05', 'Active');

INSERT INTO projects (project_name, dept_id, start_date, end_date, budget) VALUES
                                                                               ('Website Redesign', 1, '2023-01-15', '2023-12-31', 50000),
                                                                               ('Sales Campaign', 2, '2023-03-01', '2023-06-30', 30000),
                                                                               ('HR System Update', 3, '2022-11-01', '2023-02-28', 25000);

--PART B:ADVANCED INSERT OPERATIONS

--2
/*INSERT INTO employees (first_name, last_name, department)
VALUES ('Alice', 'Green', 'IT');

 */

--3
/*INSERT INTO employees (first_name, last_name, department, salary, status)
VALUES ('Bob', 'White', 'Finance', DEFAULT, DEFAULT);
*/
--4
/*INSERT INTO departments (dept_name, budget) VALUES
                                                ('Marketing', 95000),
                                                ('Operations', 110000),
                                                ('Research', 130000);
*/
--5
INSERT INTO employees (first_name, last_name, department, salary, hire_date)
VALUES ('Charlie', 'Black', 'IT', 50000 * 1.1, CURRENT_DATE);

--6
CREATE TEMPORARY TABLE temp_employees AS
SELECT * FROM employees WHERE department = 'IT';

--PART C:COMPLEX UPDATE OPERATIONS

--7
UPDATE employees SET salary = salary * 1.10;

--8
UPDATE employees
SET status = 'Senior'
WHERE salary > 60000 AND hire_date < '2020-01-01';

--9
UPDATE employees
SET department =
        CASE
            WHEN salary > 80000 THEN 'Management'
            WHEN salary BETWEEN 50000 AND 80000 THEN 'Senior'
            ELSE 'Junior'
            END;

--10
UPDATE employees
SET department = DEFAULT
WHERE status = 'Inactive';

--11
UPDATE departments
SET budget = (
    SELECT AVG(salary) * 1.20
    FROM employees
    WHERE employees.department = departments.dept_name
);

--12
UPDATE employees
SET salary = salary * 1.15,
    status = 'Promoted'
WHERE department = 'Sales';

--PART D:ADVANCED DELETE OPERATIONS

--13
DELETE FROM employees WHERE status = 'Terminated';

--14
DELETE FROM employees
WHERE salary < 40000
  AND hire_date > '2023-01-01'
  AND department IS NULL;

--15
DELETE FROM departments
WHERE dept_id NOT IN (
    SELECT DISTINCT dept_id
    FROM departments d
    WHERE EXISTS (
        SELECT 1 FROM employees e WHERE e.department = d.dept_name
    )
);

--16
DELETE FROM projects
WHERE end_date < '2023-01-01'
RETURNING *;

--PART E: OPERATIONS WITH NULL VALUES

--17
INSERT INTO employees (first_name, last_name, salary, department)
VALUES ('David', 'Lee', NULL, NULL);

-- 18
UPDATE employees
SET department = 'Unassigned'
WHERE department IS NULL;

-- 19
DELETE FROM employees
WHERE salary IS NULL OR department IS NULL;

--PART F: RETURNING CLAUSE OPERATIONS

-- 20
INSERT INTO employees (first_name, last_name, department, salary)
VALUES ('Emma', 'Davis', 'IT', 65000)
RETURNING emp_id, first_name || ' ' || last_name AS full_name;

--21
UPDATE employees
SET salary = salary + 5000
WHERE department = 'IT'
RETURNING emp_id, salary - 5000 AS old_salary, salary AS new_salary;

-- 22
DELETE FROM employees
WHERE hire_date < '2020-01-01'
RETURNING *;

-- PART G: ADVANCED DML PATTERNS

-- 23
INSERT INTO employees (first_name, last_name, department, salary)
SELECT 'Frank', 'Miller', 'IT', 60000
WHERE NOT EXISTS (
    SELECT 1 FROM employees
    WHERE first_name = 'Frank' AND last_name = 'Miller'
);

-- 24
UPDATE employees
SET salary =
        CASE
            WHEN department IN (
                SELECT dept_name FROM departments WHERE budget > 100000
            ) THEN salary * 1.10
            ELSE salary * 1.05
            END;

-- 25
INSERT INTO employees (first_name, last_name, department, salary) VALUES
                                                                      ('Grace', 'Taylor', 'IT', 48000),
                                                                      ('Henry', 'Anderson', 'Sales', 52000),
                                                                      ('Ivy', 'Martinez', 'HR', 47000),
                                                                      ('Jack', 'Garcia', 'Finance', 68000),
                                                                      ('Karen', 'Robinson', 'IT', 59000);

UPDATE employees
SET salary = salary * 1.10
WHERE first_name IN ('Grace', 'Henry', 'Ivy', 'Jack', 'Karen');

-- 26
/*CREATE TABLE employee_archive AS TABLE employees WITH NO DATA;

INSERT INTO employee_archive
SELECT * FROM employees
WHERE status = 'Inactive';

DELETE FROM employees
WHERE status = 'Inactive';
*/
-- 27
UPDATE projects
SET end_date = end_date + INTERVAL '30 days'
WHERE budget > 50000
  AND dept_id IN (
    SELECT dept_id
    FROM departments d
    WHERE (
              SELECT COUNT(*)
              FROM employees e
              WHERE e.department = d.dept_name
          ) > 3
);
